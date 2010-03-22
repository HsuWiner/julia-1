#include "llvm/DerivedTypes.h"
#include "llvm/ExecutionEngine/ExecutionEngine.h"
#include "llvm/ExecutionEngine/Interpreter.h"
#include "llvm/ExecutionEngine/JIT.h"
#include "llvm/LLVMContext.h"
#include "llvm/Module.h"
#include "llvm/ModuleProvider.h"
#include "llvm/PassManager.h"
#include "llvm/Analysis/Verifier.h"
#include "llvm/Target/TargetData.h"
#include "llvm/Target/TargetSelect.h"
#include "llvm/Transforms/Scalar.h"
#include "llvm/Support/IRBuilder.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Bitcode/ReaderWriter.h"
#include <cstdio>
#include <string>
#include <sstream>
#include <map>
#include <vector>
using namespace llvm;

extern "C" {
#ifndef NO_BOEHM_GC
#include <gc.h>
#endif
#include "llt.h"
#include "julia.h"
}

// llvm state
static LLVMContext &jl_LLVMContext = getGlobalContext();
static IRBuilder<> builder(getGlobalContext());
static Module *jl_Module;
static ExecutionEngine *jl_ExecutionEngine;
static std::map<const std::string, GlobalVariable*> stringConstants;

// types
static const Type *jl_value_llvmt;
static const Type *jl_pvalue_llvmt;
static const Type *jl_function_llvmt;
static const FunctionType *jl_func_sig;
static const Type *T_int8;
static const Type *T_int32;
static const Type *T_int64;

// global vars
static GlobalVariable *jltrue_var;
static GlobalVariable *jlfalse_var;
static GlobalVariable *jlnull_var;
static GlobalVariable *jlsysmod_var;

// important functions
static Function *jlerror_func;
static Function *jlgetbinding_func;
static Function *jltuple_func;

// head symbols for each expression type
static jl_sym_t *goto_sym;    static jl_sym_t *goto_ifnot_sym;
static jl_sym_t *label_sym;   static jl_sym_t *return_sym;
static jl_sym_t *lambda_sym;  static jl_sym_t *call_sym;
static jl_sym_t *assign_sym;  static jl_sym_t *quote_sym;
static jl_sym_t *null_sym;    static jl_sym_t *top_sym;
static jl_sym_t *boundp_sym;  static jl_sym_t *closure_ref_sym;
static jl_sym_t *body_sym;    static jl_sym_t *list_sym;
static jl_sym_t *locals_sym;  static jl_sym_t *colons_sym;
static jl_sym_t *dots_sym;

/*
  plan

  The Simplest Thing That Could Possibly Work:
  - simple code gen for all node types
  - implement all low-level intrinsics
  - instantiate-method to provide static parameters
  - rootlist to track pointers emitted into code

  stuff to fix up:
  - experiment with llvm optimization passes, option to disable them
  - function/var name mangling
  - gensyms from the front end might conflict with real variables, fix it
  - source location tracking, var name metadata
  - better error messages
  - exceptions
  - threads or other advanced control flow

  optimizations round 1:
  - constants, especially global. resolve functions statically.
  - keep a table mapping fptr to Function* for compiling known calls
  - manually inline simple builtins (tuple,box,boxset,etc.)
  - int and float constant table

  optimizations round 2:
  - lambda lifting
  - mark pure (builtin) functions and don't call them in statement position
  - avoid tuple allocation in (a,b)=(b,a)

  optimizations round 3:
  - type inference
  - mark non-null references and avoid null check
  - static method lookup
  - inlining
  - unboxing

  future:
  - try using fastcc to get tail calls
*/

static GlobalVariable *stringConst(const std::string &txt)
{
    GlobalVariable *gv = stringConstants[txt];
    static int strno = 0;
    if (gv == NULL) {
        std::stringstream ssno;
        std::string vname;
        ssno << strno;
        vname += "_j_str";
        vname += ssno.str();
        gv = new GlobalVariable(*jl_Module,
                                ArrayType::get(T_int8, txt.length()+1),
                                true,
                                GlobalVariable::ExternalLinkage,
                                ConstantArray::get(getGlobalContext(),
                                                   txt.c_str()),
                                vname);
        stringConstants[txt] = gv;
        strno++;
    }
    return gv;
}

static void emit_function(jl_expr_t *lam, Function *f);

extern "C" void jl_compile(jl_lambda_info_t *li)
{
    // objective: assign li->fptr
    Function *f = Function::Create(jl_func_sig, Function::ExternalLinkage,
                                   "a_julia_function", jl_Module);
    assert(jl_is_expr(li->ast));
    emit_function((jl_expr_t*)li->ast, f);
    verifyFunction(*f);
    li->fptr = (jl_fptr_t)jl_ExecutionEngine->getPointerToFunction(f);
    // print out the function's LLVM code
    f->dump();
}

// get array of formal argument expressions
static jl_buffer_t *lam_args(jl_expr_t *l)
{
    assert(l->head == lambda_sym);
    jl_value_t *ae = ((jl_value_t**)l->args->data)[0];
    if (ae == (jl_value_t*)jl_null) return jl_the_empty_buffer;
    assert(jl_is_expr(ae));
    assert(((jl_expr_t*)ae)->head == list_sym);
    return ((jl_expr_t*)ae)->args;
}

// get array of local var symbols
static jl_buffer_t *lam_locals(jl_expr_t *l)
{
    jl_value_t *le = ((jl_value_t**)l->args->data)[1];
    assert(jl_is_expr(le));
    jl_expr_t *lle = ((jl_expr_t**)((jl_expr_t*)le)->args->data)[0];
    assert(jl_is_expr(lle));
    assert(lle->head == locals_sym);
    return lle->args;
}

// get array of body forms
static jl_buffer_t *lam_body(jl_expr_t *l)
{
    jl_value_t *be = ((jl_value_t**)l->args->data)[2];
    assert(jl_is_expr(be));
    assert(((jl_expr_t*)be)->head == body_sym);
    return ((jl_expr_t*)be)->args;
}

static jl_sym_t *decl_var(jl_value_t *ex)
{
    if (jl_is_symbol(ex)) return (jl_sym_t*)ex;
    assert(jl_is_expr(ex));
    return ((jl_sym_t**)((jl_expr_t*)ex)->args->data)[0];
}

static int is_rest_arg(jl_value_t *ex)
{
    if (!jl_is_expr(ex)) return 0;
    if (((jl_expr_t*)ex)->head != colons_sym) return 0;
    jl_expr_t *atype = ((jl_expr_t**)((jl_expr_t*)ex)->args->data)[1];
    if (!jl_is_expr(atype)) return 0;
    if (atype->head != call_sym ||
        atype->args->length != 3)
        return 0;
    if (((jl_sym_t**)atype->args->data)[1] != dots_sym)
        return 0;
    return 1;
}

// information about the context of a piece of code: its enclosing
// function and module, and visible local variables and labels.
typedef struct {
    Function *f;
    std::map<std::string, AllocaInst*> *vars;
    std::map<std::string, BasicBlock*> *labels;
    jl_module_t *module;
    jl_expr_t *lam;
    const Argument *envArg;
    const Argument *argArray;
    const Argument *argCount;
} jl_codectx_t;

static Value *emit_expr(jl_value_t *expr, jl_codectx_t *ctx, bool value)
{
    if (jl_is_symbol(expr)) {
        // var
    }
    if (!jl_is_expr(expr)) {
        // numeric literals
        if (jl_is_int32(expr)) {
        }
        else if (jl_is_int64(expr)) {
        }
        else if (jl_is_uint64(expr)) {
        }
        else if (jl_is_float64(expr)) {
        }
        else if (jl_is_buffer(expr)) {
            // string literal
        }
        // TODO: for now just return the direct pointer
#ifdef BITS64
        return ConstantExpr::getIntToPtr(ConstantInt::get(T_int64, (uint64_t)expr),
                                         jl_pvalue_llvmt);
#else
        return ConstantExpr::getIntToPtr(ConstantInt::get(T_int32, (uint64_t)expr),
                                         jl_pvalue_llvmt);
#endif
        assert(0);
    }
    jl_expr_t *ex = (jl_expr_t*)expr;
    jl_value_t **args = (jl_value_t**)ex->args->data;
    // this is object-disoriented.
    // however, this is a good way to do it because it should *not* be easy
    // to add new node types.
    if (ex->head == goto_sym) {
        assert(!value);
    }
    else if (ex->head == goto_ifnot_sym) {
        assert(!value);
    }
    else if (ex->head == label_sym) {
        assert(!value);
    }

    else if (ex->head == return_sym) {
        assert(!value);
        builder.CreateRet(emit_expr(args[0], ctx, true));
    }
    else if (ex->head == call_sym) {
    }

    else if (ex->head == assign_sym) {
        assert(!value);
    }
    else if (ex->head == top_sym) {
    }
    else if (ex->head == boundp_sym) {
    }
    else if (ex->head == closure_ref_sym) {
    }

    else if (ex->head == quote_sym) {
    }
    else if (ex->head == null_sym) {
        return builder.CreateLoad(jlnull_var, false);
    }
    //TODO: temporary
    if (value)
        return builder.CreateLoad(jlnull_var, false);
    assert(!value);
    return NULL;
}

static void emit_function(jl_expr_t *lam, Function *f)
{
    BasicBlock *b0 = BasicBlock::Create(jl_LLVMContext, "top", f);
    builder.SetInsertPoint(b0);
    std::map<std::string, AllocaInst*> localVars;
    std::map<std::string, BasicBlock*> labels;
    jl_buffer_t *largs = lam_args(lam);
    jl_buffer_t *lvars = lam_locals(lam);
    Function::arg_iterator AI = f->arg_begin();
    const Argument &envArg = *AI++;
    const Argument &argArray = *AI++;
    const Argument &argCount = *AI++;
    jl_codectx_t ctx;
    ctx.f = f;
    ctx.vars = &localVars;
    ctx.labels = &labels;
    ctx.module = jl_system_module; //TODO
    ctx.lam = lam;
    ctx.envArg = &envArg;
    ctx.argArray = &argArray;
    ctx.argCount = &argCount;

    // check arg count
    size_t nreq = largs->length;
    int va = 0;
    std::vector<Value *> zeros(0);
    zeros.push_back(ConstantInt::get(T_int32, 0));
    zeros.push_back(ConstantInt::get(T_int32, 0));
    if (nreq > 0 && is_rest_arg(((jl_value_t**)largs->data)[nreq-1])) {
        nreq--;
        va = 1;
        Value *enough =
            builder.CreateICmpUGE((Value*)&argCount,
                                  ConstantInt::get(T_int32, nreq));
        BasicBlock *elseBB = BasicBlock::Create(getGlobalContext(), "else", f);
        BasicBlock *mergeBB = BasicBlock::Create(getGlobalContext(), "ifcont");
        builder.CreateCondBr(enough, mergeBB, elseBB);
        builder.SetInsertPoint(elseBB);
        // throw error
        builder.CreateCall(jlerror_func,
                           builder.CreateGEP(stringConst("Too few arguments"),
                                             zeros.begin(), zeros.end()));
        builder.CreateBr(mergeBB);
        f->getBasicBlockList().push_back(mergeBB);
        builder.SetInsertPoint(mergeBB);
    }
    else {
        Value *enough =
            builder.CreateICmpEQ((Value*)&argCount,
                                 ConstantInt::get(T_int32, nreq));
        BasicBlock *elseBB = BasicBlock::Create(getGlobalContext(), "else", f);
        BasicBlock *mergeBB = BasicBlock::Create(getGlobalContext(), "ifcont");
        builder.CreateCondBr(enough, mergeBB, elseBB);
        builder.SetInsertPoint(elseBB);
        // throw error
        builder.CreateCall(jlerror_func,
                           builder.CreateGEP(stringConst("Wrong number of arguments"), zeros.begin(), zeros.end()));
        builder.CreateBr(mergeBB);
        f->getBasicBlockList().push_back(mergeBB);
        builder.SetInsertPoint(mergeBB);
    }

    // move args into local variables
    // (probably possible to avoid this step with a little redesign)
    size_t i;
    for(i=0; i < nreq; i++) {
        char *argname = decl_var(((jl_value_t**)largs->data)[i])->name;
        AllocaInst *lv = builder.CreateAlloca(jl_pvalue_llvmt, 0, argname);
        Value *argPtr =
            builder.CreateGEP((Value*)&argArray,
                              ConstantInt::get(T_int32, i));
        LoadInst *theArg = builder.CreateLoad(argPtr, false);
        builder.CreateStore(theArg, lv);
        localVars[argname] = lv;
    }
    // allocate rest argument if necessary
    if (va) {
        // restarg = jl_f_tuple(NULL, &args[nreq], nargs-nreq)
        Value *restTuple =
            builder.CreateCall3(jltuple_func,
                                Constant::getNullValue(jl_pvalue_llvmt),
                                builder.CreateGEP((Value*)&argArray,
                                                  ConstantInt::get(T_int32,nreq)),
                                builder.CreateSub((Value*)&argCount,
                                                  ConstantInt::get(T_int32,nreq)));
        char *argname = decl_var(((jl_value_t**)largs->data)[nreq])->name;
        AllocaInst *lv = builder.CreateAlloca(jl_pvalue_llvmt, 0, argname);
        builder.CreateStore(restTuple, lv);
        localVars[argname] = lv;
    }

    // allocate local variables
    for(i=0; i < lvars->length; i++) {
        char *argname = ((jl_sym_t**)lvars->data)[i]->name;
        AllocaInst *lv = builder.CreateAlloca(jl_pvalue_llvmt, 0, argname);
        localVars[argname] = lv;
    }

    jl_buffer_t *stmts = lam_body(lam);
    // associate labels with basic blocks so forward jumps can be resolved
    for(i=0; i < stmts->length; i++) {
        jl_value_t *ex = ((jl_value_t**)stmts->data)[i];
        if (jl_is_expr(ex) && ((jl_expr_t*)ex)->head == label_sym) {
            char *lname = ((jl_sym_t**)((jl_expr_t*)ex)->args->data)[0]->name;
            labels[lname] = BasicBlock::Create(getGlobalContext(), lname);
        }
    }
    // compile body statements
    for(i=0; i < stmts->length; i++) {
        (void)emit_expr(((jl_value_t**)stmts->data)[i], &ctx, false);
    }
    // all bodies must end in a return
}

static GlobalVariable *global_to_llvm(const std::string &cname, void *addr)
{
    GlobalVariable *gv;
    gv = new GlobalVariable(*jl_Module, jl_pvalue_llvmt,
                            true, GlobalVariable::ExternalLinkage,
                            NULL, cname);
    jl_ExecutionEngine->addGlobalMapping(gv, addr);
    return gv;
}

extern "C" JL_CALLABLE(jl_f_tuple);

static void init_julia_llvm_env(Module *m)
{
    T_int32 = Type::getInt32Ty(getGlobalContext());
    T_int64 = Type::getInt64Ty(getGlobalContext());
    T_int8  = Type::getInt8Ty(getGlobalContext());

    // add needed base definitions to our LLVM environment
    MemoryBuffer *deffile = MemoryBuffer::getFile("julia-defs.s.bc");
    Module *jdefs = ParseBitcodeFile(deffile, getGlobalContext());
    delete deffile;

    jl_value_llvmt = jdefs->getTypeByName("struct._jl_value_t");
    jl_pvalue_llvmt = PointerType::get(jl_value_llvmt, 0);
    jl_func_sig = dynamic_cast<const FunctionType*>(jdefs->getTypeByName("jl_callable_t"));
    assert(jl_func_sig != NULL);
    jl_function_llvmt = jdefs->getTypeByName("jl_function_t");

    jltrue_var = global_to_llvm("jl_true", (void*)&jl_true);
    jlfalse_var = global_to_llvm("jl_false", (void*)&jl_false);
    jlnull_var = global_to_llvm("jl_null", (void*)&jl_null);
    jlsysmod_var = global_to_llvm("jl_system_module", (void*)&jl_system_module);

    std::vector<const Type*> args1(0);
    args1.push_back(PointerType::get(T_int8, 0));
    jlerror_func =
        Function::Create(FunctionType::get(Type::getVoidTy(jl_LLVMContext),
                                           args1, false),
                         Function::ExternalLinkage,
                         "jl_error", jl_Module);
    jl_ExecutionEngine->addGlobalMapping(jlerror_func, (void*)&jl_error);

    std::vector<const Type *> args2(0);
    args2.push_back(PointerType::get(T_int8,0));
    args2.push_back(PointerType::get(T_int8,0));
    jlgetbinding_func =
        Function::Create(FunctionType::get(PointerType::get(jl_pvalue_llvmt,0),
                                           args2, false),
                         Function::ExternalLinkage,
                         "jl_get_bindingp", jl_Module);
    jl_ExecutionEngine->addGlobalMapping(jlgetbinding_func,
                                         (void*)&jl_get_bindingp);

    jltuple_func =
        Function::Create(jl_func_sig, Function::ExternalLinkage,
                         "jl_f_tuple", jl_Module);
    jl_ExecutionEngine->addGlobalMapping(jltuple_func, (void*)*jl_f_tuple);
}

extern "C" void jl_init_codegen()
{
    InitializeNativeTarget();
    jl_Module = new Module("julia", jl_LLVMContext);
    jl_ExecutionEngine = EngineBuilder(jl_Module).create();

    init_julia_llvm_env(jl_Module);

    goto_sym = jl_symbol("goto");
    goto_ifnot_sym = jl_symbol("goto-ifnot");
    label_sym = jl_symbol("label");
    return_sym = jl_symbol("return");
    lambda_sym = jl_symbol("lambda");
    call_sym = jl_symbol("call");
    assign_sym = jl_symbol("assign");
    quote_sym = jl_symbol("quote");
    null_sym = jl_symbol("null");
    top_sym = jl_symbol("top");
    boundp_sym = jl_symbol("boundp");
    closure_ref_sym = jl_symbol("closure-ref");
    body_sym = jl_symbol("body");
    list_sym = jl_symbol("list");
    locals_sym = jl_symbol("locals");
    colons_sym = jl_symbol("::");
    dots_sym = jl_symbol("...");
}
