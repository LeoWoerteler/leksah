{-# LANGUAGE CPP, ScopedTypeVariables #-}
-----------------------------------------------------------------------------
--
-- Module      :  IDE.LogRef
-- Copyright   :  (c) Juergen Nicklisch-Franken, Hamish Mackenzie
-- License     :  GNU-GPL
--
-- Maintainer  :  <maintainer at leksah.org>
-- Stability   :  provisional
-- Portability :  portable
--
--
-- |
--
---------------------------------------------------------------------------------


module IDE.LogRef (
    nextError
,   previousError
,   nextBreakpoint
,   previousBreakpoint
,   markLogRefs
,   unmarkLogRefs
,   defaultLineLogger
,   defaultLineLogger'
,   logOutputLines
,   logOutputLines_
,   logOutput
,   logOutputForBuild
,   logOutputForBreakpoints
,   logOutputForSetBreakpoint
,   logOutputForLiveContext
,   logOutputForHistoricContext
,   selectRef
,   setBreakpointList
,   showSourceSpan
,   srcSpanParser
) where

import Graphics.UI.Gtk
import Control.Monad.Reader
import Text.ParserCombinators.Parsec.Language
import Text.ParserCombinators.Parsec hiding(Parser)
import qualified Text.ParserCombinators.Parsec.Token as P

import IDE.Core.State
import IDE.TextEditor
import IDE.Pane.SourceBuffer
import IDE.Pane.Log
import IDE.Utils.Tool
import System.FilePath (equalFilePath)
import Data.List (stripPrefix, elemIndex, isPrefixOf)
import Data.Maybe (catMaybes)
import System.Exit (ExitCode(..))
import System.Log.Logger (debugM)
import IDE.Utils.FileUtils(myCanonicalizePath)

showSourceSpan :: LogRef -> String
showSourceSpan = displaySrcSpan . logRefSrcSpan

selectRef :: Maybe LogRef -> IDEAction
selectRef (Just ref) = do
    logRefs <- readIDE allLogRefs
    case elemIndex ref logRefs of
        Nothing    -> liftIO $ debugM "leksah" "no index" >> return ()
        Just index -> do
            mbBuf         <- selectSourceBuf (logRefFullFilePath ref)
            case mbBuf of
                Just buf  -> markRefInSourceBuf index buf ref True
                Nothing   -> liftIO $ debugM "leksah" "no buf" >> return ()
            log :: IDELog <- getLog
            liftIO $ markErrorInLog log (logLines ref)
selectRef Nothing = return ()

forOpenLogRefs :: (Int -> LogRef -> IDEBuffer -> IDEAction) -> IDEAction
forOpenLogRefs f = do
    logRefs <- readIDE allLogRefs
    allBufs <- allBuffers
    forM_ [0 .. ((length logRefs)-1)] (\index -> do
        let ref = logRefs !! index
            fp = logRefFullFilePath ref
        fpc <- liftIO $ myCanonicalizePath fp
        forM_ (filter (\buf -> case (fileName buf) of
                Just fn -> equalFilePath fpc fn
                Nothing -> False) allBufs) (f index ref))

markLogRefs :: IDEAction
markLogRefs = do
    forOpenLogRefs $ \index logRef buf -> markRefInSourceBuf index buf logRef False

unmarkLogRefs :: IDEAction
unmarkLogRefs = do
    forOpenLogRefs $ \index logRef buf -> do
            gtkbuf  <-  getBuffer (sourceView buf)
            i1      <-  getStartIter gtkbuf
            i2      <-  getEndIter gtkbuf
            removeTagByName gtkbuf (show (logRefType logRef) ++ show index)  i1 i2

setErrorList :: [LogRef] -> IDEAction
setErrorList errs = do
    unmarkLogRefs
    breaks <- readIDE breakpointRefs
    contexts <- readIDE contextRefs
    modifyIDE_ (\ide -> ide{allLogRefs = errs ++ breaks ++ contexts})
    setCurrentError Nothing
    markLogRefs
    triggerEventIDE ErrorChanged
    return ()

setBreakpointList :: [LogRef] -> IDEAction
setBreakpointList breaks = do
    ideR <- ask
    unmarkLogRefs
    errs <- readIDE errorRefs
    contexts <- readIDE contextRefs
    modifyIDE_ (\ide -> ide{allLogRefs = errs ++ breaks ++ contexts})
    setCurrentBreak Nothing
    markLogRefs
    triggerEventIDE BreakpointChanged
    return ()

addLogRefs :: [LogRef] -> IDEAction
addLogRefs refs = do
    ideR <- ask
    unmarkLogRefs
    modifyIDE_ (\ide -> ide{allLogRefs = (allLogRefs ide) ++ refs})
    setCurrentError Nothing
    markLogRefs
    triggerEventIDE ErrorChanged
    triggerEventIDE BreakpointChanged
    triggerEventIDE TraceChanged
    return ()

nextError :: IDEAction
nextError = do
    errs <- readIDE errorRefs
    currentError <- readIDE currentError
    if null errs
        then return ()
        else do
            let new = case currentError of
                        Nothing -> 0
                        Just ref ->
                            case elemIndex ref errs of
                                Nothing -> 0
                                Just n | (n + 1) < length errs -> (n + 1)
                                Just n -> n
            setCurrentError (Just $ errs!!new)
            selectRef $ Just (errs!!new)

previousError :: IDEAction
previousError = do
    errs <- readIDE errorRefs
    currentError <- readIDE currentError
    if null errs
        then return ()
        else do
            let new = case currentError of
                        Nothing -> (length errs - 1)
                        Just ref ->
                            case elemIndex ref errs of
                                Nothing -> (length errs - 1)
                                Just n | n > 0 -> (n - 1)
                                Just n -> 0
            setCurrentError (Just $ errs!!new)
            selectRef $ Just (errs!!new)

nextBreakpoint :: IDEAction
nextBreakpoint = do
    breaks <- readIDE breakpointRefs
    currentBreak <- readIDE currentBreak
    if null breaks
        then return ()
        else do
            let new = case currentBreak of
                        Nothing -> 0
                        Just ref ->
                            case elemIndex ref breaks of
                                Nothing -> 0
                                Just n | (n + 1) < length breaks -> (n + 1)
                                Just n -> n
            setCurrentBreak (Just $ breaks!!new)
            selectRef $ Just (breaks!!new)

previousBreakpoint :: IDEAction
previousBreakpoint = do
    breaks <- readIDE breakpointRefs
    currentBreak <- readIDE currentBreak
    if null breaks
        then return ()
        else do
            let new = case currentBreak of
                        Nothing -> (length breaks - 1)
                        Just ref ->
                            case elemIndex ref breaks of
                                Nothing -> (length breaks - 1)
                                Just n | n > 0 -> (n - 1)
                                Just n -> 0
            setCurrentBreak (Just $ breaks!!new)
            selectRef $ Just (breaks!!new)

nextContext :: IDEAction
nextContext = do
    contexts <- readIDE contextRefs
    currentContext <- readIDE currentContext
    if null contexts
        then return ()
        else do
            let new = case currentContext of
                        Nothing -> 0
                        Just ref ->
                            case elemIndex ref contexts of
                                Nothing -> 0
                                Just n | (n + 1) < length contexts -> (n + 1)
                                Just n -> n
            setCurrentContext (Just $ contexts!!new)
            selectRef $ Just (contexts!!new)

previousContext :: IDEAction
previousContext = do
    contexts <- readIDE contextRefs
    currentContext <- readIDE currentContext
    if null contexts
        then return ()
        else do
            let new = case currentContext of
                        Nothing -> (length contexts - 1)
                        Just ref ->
                            case elemIndex ref contexts of
                                Nothing -> (length contexts - 1)
                                Just n | n > 0 -> (n - 1)
                                Just n -> 0
            setCurrentContext (Just $ contexts!!new)
            selectRef $ Just (contexts!!new)

lastContext :: IDEAction
lastContext = do
    contexts <- readIDE contextRefs
    currentContext <- readIDE currentContext
    if null contexts
        then return ()
        else do
            let new = (last contexts)
            setCurrentContext (Just new)
            selectRef $ Just new

#if MIN_VERSION_ghc(7,0,1)
fixColumn c = max 0 (c - 1)
#else
fixColumn = id
#endif

srcSpanParser :: CharParser () SrcSpan
srcSpanParser = try (do
        filePath <- many (noneOf ":")
        char ':'
        char '('
        beginLine <- int
        char ','
        beginCol <- int
        char ')'
        char '-'
        char '('
        endLine <- int
        char ','
        endCol <- int
        char ')'
        return $ SrcSpan filePath beginLine (fixColumn beginCol) endLine (fixColumn endCol))
    <|> try (do
        filePath <- many (noneOf ":")
        char ':'
        line <- int
        char ':'
        beginCol <- int
        char '-'
        endCol <- int
        return $ SrcSpan filePath line (fixColumn beginCol) line (fixColumn endCol))
    <|> try (do
        filePath <- many (noneOf ":")
        char ':'
        line <- int
        char ':'
        col <- int
        return $ SrcSpan filePath line (fixColumn col) line (fixColumn col))
    <?> "srcLocParser"

data BuildError =   BuildLine
                |   EmptyLine
                |   ErrorLine SrcSpan LogRefType String
                |   WarningLine String
                |   OtherLine String

buildLineParser :: CharParser () BuildError
buildLineParser = try (do
        char '['
        int
        symbol "of"
        int
        char ']'
        many (anyChar)
        return BuildLine)
    <|> try (do
        whiteSpace
        span <- srcSpanParser
        char ':'
        whiteSpace
        refType <- try (do
                symbol "Warning:"
                return WarningRef)
            <|> return ErrorRef
        text <- many anyChar
        return (ErrorLine span refType text))
    <|> try (do
        whiteSpace
        eof
        return EmptyLine)
    <|> try (do
        whiteSpace
        symbol "Warning:"
        text <- many anyChar
        return (WarningLine ("Warning:" ++ text)))
    <|> try (do
        text <- many anyChar
        eof
        return (OtherLine text))
    <?> "buildLineParser"

data BreakpointDescription = BreakpointDescription Int SrcSpan

breaksLineParser :: CharParser () BreakpointDescription
breaksLineParser = try (do
        char '['
        n <- int
        char ']'
        whiteSpace
        many (noneOf " ")
        whiteSpace
        span <- srcSpanParser
        return (BreakpointDescription n span))
    <?> "buildLineParser"

setBreakpointLineParser :: CharParser () BreakpointDescription
setBreakpointLineParser = try (do
        symbol "Breakpoint"
        whiteSpace
        n <- int
        whiteSpace
        symbol "activated"
        whiteSpace
        symbol "at"
        whiteSpace
        span <- srcSpanParser
        return (BreakpointDescription n span))
    <?> "setBreakpointLineParser"

lexer = P.makeTokenParser emptyDef
lexeme = P.lexeme lexer
whiteSpace = P.whiteSpace lexer
hexadecimal = P.hexadecimal lexer
symbol = P.symbol lexer
identifier = P.identifier lexer
colon = P.colon lexer
int = fmap fromInteger $ P.integer lexer

defaultLineLogger :: IDELog -> ToolOutput -> IDEM Int
defaultLineLogger log out = liftIO $ defaultLineLogger' log out

defaultLineLogger' :: IDELog -> ToolOutput -> IO Int
defaultLineLogger' log out = do
    case out of
        ToolInput  line            -> appendLog log (line ++ "\n") InputTag
        ToolOutput line            -> appendLog log (line ++ "\n") LogTag
        ToolError  line            -> appendLog log (line ++ "\n") ErrorTag
        ToolPrompt                 -> appendLog log (concat (take 20 (repeat "- ")) ++ "-\n") FrameTag
        ToolExit   ExitSuccess     -> appendLog log (take 41 (repeat '-') ++ "\n") FrameTag
        ToolExit   (ExitFailure 1) -> appendLog log (take 41 (repeat '=') ++ "\n") FrameTag
        ToolExit   (ExitFailure n) -> appendLog log (take 41 ("========== " ++ show n ++ " " ++ repeat '=') ++ "\n") FrameTag

logOutputLines :: (IDELog -> ToolOutput -> IDEM a) -> [ToolOutput] -> IDEM [a]
logOutputLines lineLogger output = do
    log :: IDELog <- getLog
    liftIO $ bringPaneToFront log
    results <- forM output $ lineLogger log
    triggerEventIDE (StatusbarChanged [CompartmentState "", CompartmentBuild False])
    return results

logOutputLines_ :: (IDELog -> ToolOutput -> IDEM a) -> [ToolOutput] -> IDEAction
logOutputLines_ lineLogger output = do
    logOutputLines lineLogger output
    return ()

logOutput :: [ToolOutput] -> IDEM ()
logOutput output = do
    logOutputLines defaultLineLogger output
    return ()

logOutputForBuild :: IDEPackage -> Bool -> [ToolOutput] -> IDEAction
logOutputForBuild package backgroundBuild output = do
    ideRef <- ask
    log    <- getLog
    unless backgroundBuild $ liftIO $ bringPaneToFront log
    errs   <- liftIO $ readAndShow output ideRef log False []
    setErrorList $ reverse errs
    triggerEventIDE (Sensitivity [(SensitivityError,not (null errs))])
    let errorNum    =   length (filter isError errs)
    let warnNum     =   length errs - errorNum
    triggerEventIDE (StatusbarChanged [CompartmentState
        (show errorNum ++ " Errors, " ++ show warnNum ++ " Warnings"), CompartmentBuild False])
    unless backgroundBuild nextError
    return ()
    where
    readAndShow :: [ToolOutput] -> IDERef -> IDELog -> Bool -> [LogRef] -> IO [LogRef]
    readAndShow [] _ log _ errs = do
        appendLog log ("----- Leksah Error Please Report -----\n") FrameTag
        return errs
    readAndShow (output:remainingOutput) ideR log inError errs = do
        case output of
            ToolError line -> do
                let parsed  =  parse buildLineParser "" line
                let nonErrorPrefixes = ["Linking ", "ar:", "ld:", "ld warning:"]
                tag <- case parsed of
                    Right BuildLine -> return InfoTag
                    Right (OtherLine text) | "Linking " `isPrefixOf` text -> do
                        -- when backgroundBuild $ reflectIDE interruptProcess ideR
                        postGUIAsync $ reflectIDE (do
                                setErrorList $ reverse errs
                            ) ideR
                        return InfoTag
                    Right (OtherLine text) | any (`isPrefixOf` text) nonErrorPrefixes -> do
                        return InfoTag
                    _ -> return ErrorTag
                lineNr <- appendLog log (line ++ "\n") tag
                case (parsed, errs) of
                    (Left e,_) -> do
                        sysMessage Normal (show e)
                        readAndShow remainingOutput ideR log False errs
                    (Right ne@(ErrorLine span refType str),_) ->
                        readAndShow remainingOutput ideR log True ((LogRef span package str (lineNr,lineNr) refType):errs)
                    (Right (OtherLine str1),(LogRef span rootPath str (l1,l2) refType):tl) ->
                        if inError
                            then readAndShow remainingOutput ideR log True ((LogRef span
                                                    rootPath
                                                    (if null str
                                                        then line
                                                        else str ++ "\n" ++ line)
                                                    (l1,lineNr) refType) : tl)
                            else readAndShow remainingOutput ideR log False errs
                    (Right (WarningLine str1),(LogRef span rootPath str (l1,l2) isError):tl) ->
                        if inError
                            then readAndShow remainingOutput ideR log True ((LogRef span
                                                    rootPath
                                                    (if null str
                                                        then line
                                                        else str ++ "\n" ++ line)
                                                    (l1,lineNr) WarningRef) : tl)
                            else readAndShow remainingOutput ideR log False errs
                    otherwise -> readAndShow remainingOutput ideR log False errs
            ToolOutput line -> do
                appendLog log (line ++ "\n") LogTag
                readAndShow remainingOutput ideR log inError errs
            ToolInput line -> do
                appendLog log (line ++ "\n") InputTag
                readAndShow remainingOutput ideR log inError errs
            ToolPrompt -> do
                let errorNum    =   length (filter isError errs)
                let warnNum     =   length errs - errorNum
                case errs of
                    [] -> defaultLineLogger' log output
                    _ -> appendLog log ("- - - " ++ show errorNum ++ " errors - "
                                            ++ show warnNum ++ " warnings - - -\n") FrameTag
                return errs
            ToolExit _ -> do
                let errorNum    =   length (filter isError errs)
                let warnNum     =   length errs - errorNum
                case errs of
                    [] -> defaultLineLogger' log output
                    _ -> appendLog log ("----- " ++ show errorNum ++ " errors -- "
                                            ++ show warnNum ++ " warnings -----\n") FrameTag
                return errs

logOutputForBreakpoints :: IDEPackage -> [ToolOutput] -> IDEAction
logOutputForBreakpoints package output = do
    breaks <- logOutputLines (\log out -> do
        case out of
            ToolOutput line -> do
                logLineNumber <- liftIO $ appendLog log (line ++ "\n") LogTag
                case parse breaksLineParser "" line of
                    Right (BreakpointDescription n span) ->
                        return $ Just $ LogRef span package line (logLineNumber, logLineNumber) BreakpointRef
                    _ -> return Nothing
            _ -> do
                defaultLineLogger log out
                return Nothing) output
    setBreakpointList $ catMaybes breaks

logOutputForSetBreakpoint :: IDEPackage -> [ToolOutput] -> IDEAction
logOutputForSetBreakpoint package output = do
    breaks <- logOutputLines (\log out -> do
        case out of
            ToolOutput line -> do
                logLineNumber <- liftIO $ appendLog log (line ++ "\n") LogTag
                case parse setBreakpointLineParser "" line of
                    Right (BreakpointDescription n span) ->
                        return $ Just $ LogRef span package line (logLineNumber, logLineNumber) BreakpointRef
                    _ -> return Nothing
            _ -> do
                defaultLineLogger log out
                return Nothing) output
    addLogRefs $ catMaybes breaks

logOutputForContext :: IDEPackage -> (String -> [SrcSpan]) -> [ToolOutput] -> IDEAction
logOutputForContext package getContexts output = do
    refs <- fmap catMaybes $ logOutputLines (\log out -> do
        case out of
            ToolOutput line -> do
                logLineNumber <- liftIO $ appendLog log (line ++ "\n") LogTag
                let contexts = getContexts line
                if null contexts
                    then return Nothing
                    else return $ Just $ LogRef (last contexts) package line (logLineNumber, logLineNumber) ContextRef
            _ -> do
                defaultLineLogger log out
                return Nothing) output
    unless (null refs) $ do
        addLogRefs [last refs]
        lastContext

logOutputForLiveContext :: IDEPackage -> [ToolOutput] -> IDEAction
logOutputForLiveContext package = logOutputForContext package getContexts
    where
        getContexts [] = []
        getContexts line@(x:xs) = case stripPrefix "Stopped at " line of
            Just rest -> case parse srcSpanParser "" rest of
                Right desc -> desc : getContexts xs
                _          -> getContexts xs
            _ -> getContexts xs

logOutputForHistoricContext :: IDEPackage -> [ToolOutput] -> IDEAction
logOutputForHistoricContext package = logOutputForContext package getContexts
    where
        getContexts line = case stripPrefix "Logged breakpoint at " line of
            Just rest -> case parse srcSpanParser "" rest of
                Right desc -> [desc]
                _          -> []
            _ -> []

