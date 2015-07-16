module GenCode where

import Environment
import Intermed
import AssignAddr

import Data.List
import Control.Monad.State

type Asm = String

type LabelEnv = State (Int, Int)


runLabelEnv :: LabelEnv a -> a
runLabelEnv s = evalState s (0, 0)


withLineBreaks :: [String] -> String
withLineBreaks = concat . intersperse "\n"


getFuncFrameSize :: IStmt -> Int
getFuncFrameSize (ICompoundStmt decls stmts)
  = minimum $ (map getFpAddr decls) ++ (map getFuncFrameSize stmts)
getFuncFrameSize _ = 0


setStackPointer :: Int -> LabelEnv ()
setStackPointer size = do
  (n, m) <- get
  put (n, size)


-- 引数は$spの下に積んでいく
setArgs :: [IVar] -> [Asm]
setArgs args = fst $ foldr foldArgs ([], -4) args
  where
    foldArgs :: IVar -> ([Asm], Int) -> ([Asm], Int)
    foldArgs arg (asm, curAddr) = 
      ([prettyInst ["lw", "$t0", show arg]
       ,prettyInst ["sw", "$t0", show curAddr ++ "($sp)"]] ++ asm,
      curAddr - wordSize)


prettyInst :: [String] -> String
prettyInst (op:args) = concat ["    ", op, " ", concat (intersperse ", " args)]


{-==========================
 -      genCode
 -==========================-}
genCode :: IProgram -> Asm
genCode prog = header ++ body
  where header = "    .text" ++ "\n" ++ "    .globl main" ++  "\n"
        body   = runLabelEnv (do asm <- mapM genIExDecl prog
                                 return $ withLineBreaks asm)


genIExDecl :: IExDecl -> LabelEnv Asm
genIExDecl (IFuncDef (VarInfo func) args body) = do
  let fpSize = (length args) * wordSize
      spSize = (abs $ getFuncFrameSize body) +
               fpSize +     -- 引数のため
               wordSize * 2 -- $fp, $raのための空間
  setStackPointer (-spSize)
  stmt <- genStmt body
  return (withLineBreaks $ 
            [(fst func) ++ ":"
         -- $spを後にfpの基軸とするために退避しておく
            ,prettyInst ["move", "$t0", "$sp"]
         -- スタックにスペースを確保
            ,prettyInst ["addi","$sp", "$sp", show (-spSize)]
            ,prettyInst ["sw", "$fp", "0($sp)"] -- fpを退避
            ,prettyInst ["sw", "$ra", "4($sp)"] -- raを退避
         -- fpを移動し引数のためのスペースを確保
            ,prettyInst ["addi", "$fp", "$t0", show (-fpSize)]]
         ++ stmt
         -- 呼び出し元に制御を戻す
         ++ [prettyInst ["lw", "$ra", "4($sp)"] -- raを復元
            ,prettyInst ["lw", "$fp", "0($sp)"] -- fpを復元
            -- spを復元
            ,prettyInst ["addi", "$sp", "$sp", show spSize] 
            ,prettyInst ["jr", "$ra"]] -- 制御を呼び出し元に戻す
         )
genIExDecl _ = return ""


genStmt :: IStmt -> LabelEnv [Asm]
genStmt (IEmptyStmt) = return [""]
genStmt (ILetStmt dest srcExpr) = do
  expr <- genExpr srcExpr
  return $ expr ++ [prettyInst ["sw", "$t0", show dest]]
genStmt (IWriteStmt dest src) =
  return $ [prettyInst ["lw", "$t0", show src]
           ,prettyInst ["lw", "$t1", show dest]
           ,prettyInst ["sw", "$t0", "0($t1)"]]
genStmt (IReadStmt dest src) =
  return $ [prettyInst ["lw", "$t1", show src]
           ,prettyInst ["lw", "$t0", "0($t1)"]
           ,prettyInst ["sw", "$t0", show dest]]
genStmt (ICallStmt dest f args) =
  if (getType $ snd f) == ChVoid
  then return withoutReturn
  else return $ withoutReturn ++ 
                [prettyInst ["sw", "$v0", show dest]]
    where withoutReturn = setArgs args ++ 
                          [prettyInst ["jal", fst f]]
genStmt (IReturnStmt retvar) =
  return $ [prettyInst ["lw", "$v0", show retvar]]
genStmt (IPrintStmt var) =
  return $ [prettyInst ["li", "$v0", show 1]
           ,prettyInst ["lw", "$a0", show var]
           ,"    syscall"]
genStmt (ICompoundStmt decls stmts) = liftM concat (mapM genStmt stmts)

genExpr :: IExpr -> LabelEnv [Asm]
genExpr (IVarExpr var) =
  return $ [prettyInst ["lw", "$t0", show var]]
genExpr (IIntExpr num) =
  return $ [prettyInst ["li", "$t0", show num]]
genExpr (IAopExpr op v1 v2) = 
  return $ [prettyInst ["lw", "$t1", show v1]
           ,prettyInst ["lw", "$t2", show v2]] ++ genAop op
genExpr (IAddrExpr (VarAddr addr)) =
  case addr of
    (Fp n) -> return $ [prettyInst ["addi", "$t0", "$fp", show n]]
    (Gp n) -> return $ [prettyInst ["addi", "$t0", "$gp", show n]]


genAop :: String -> [String]
genAop "+" = [prettyInst ["add",  "$t0", "$t1", "$t2"]]
genAop "-" = [prettyInst ["sub",  "$t0", "$t1", "$t2"]]
genAop "*" = [prettyInst ["mult", "$t1", "$t2"]
             ,prettyInst ["mflo", "$t0"]]
genAop "/" = [prettyInst ["div",  "$t1", "$t2"]
             ,prettyInst ["mflo", "$t0"]]
