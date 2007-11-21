{-# OPTIONS_GHC -fglasgow-exts #-}
-----------------------------------------------------------------------------
--
-- Module      :  Ghf.InfoPane
-- Copyright   :  (c) Juergen Nicklisch-Franken (aka Jutaro)
-- License     :  GNU-GPL
--
-- Maintainer  :  Juergen Nicklisch-Franken <jnf at arcor.de>
-- Stability   :  experimental
-- Portability :  portable
--
-- | The GUI stuff for infos
--
-------------------------------------------------------------------------------

module Ghf.InfoPane (
    initInfo
,   setInfo
) where

import Graphics.UI.Gtk hiding (afterToggleOverwrite)
import Graphics.UI.Gtk.SourceView
import Graphics.UI.Gtk.ModelView as New
import Graphics.UI.Gtk.Multiline.TextView
import Control.Monad.Reader
import Data.IORef
import System.IO
import qualified Data.Map as Map
import Data.Map (Map,(!))
import Config
import Control.Monad
import Control.Monad.Trans
import System.FilePath
import System.Directory
import Data.Map (Map)
import qualified Data.Map as Map
import GHC hiding (getInfo)
import System.IO
import Control.Concurrent
import qualified Distribution.Package as DP
import Distribution.PackageDescription hiding (package)
--import Distribution.InstalledPackageInfo
import Distribution.Version
import Data.List
import UniqFM
import PackageConfig
import Data.Maybe

import Ghf.File
import Ghf.Core.State
import Ghf.SourceCandy
import Ghf.ViewFrame
import Ghf.SpecialEditors
import Ghf.Log
import GUI.Ghf.EditorBasics
import GUI.Ghf.MakeEditor
import GUI.Ghf.SimpleEditors
import GUI.Ghf.CompositeEditors
import GUI.Ghf.Parameters
import Data.Ghf.Default

instance Pane GhfInfo
    where
    primPaneName _  =   "Info"
    getAddedIndex _ =   0
    getTopWidget    =   castToWidget . sw
    paneId b        =   "*Info"

instance SpecialPane GhfInfo where
    saveState p     =   do
        mbIdDescr <- getInfo
        lift $ putStrLn $ "nowRecovering " ++ show  mbIdDescr
        case mbIdDescr of
            Nothing -> return Nothing
            Just idDescr -> return (Just (InfoState idDescr))
    recoverState pp (InfoState iddescr) _  =   do
        nb <- getNotebook pp
        initInfo pp nb iddescr
        return ()
    makeActive pane = activatePane pane (BufConnections[][][])
    close pane     =   do
        (panePath,_)    <-  guiPropertiesFromName (paneName pane)
        nb              <-  getNotebook panePath
        mbI             <-  lift $notebookPageNum nb (getTopWidget pane)
        case mbI of
            Nothing ->  lift $ do
                putStrLn "notebook page not found: unexpected"
                return ()
            Just i  ->  do
                deactivatePaneIfActive pane
                lift $notebookRemovePage nb i
                removePaneAdmin pane

instance Castable GhfInfo where
    casting _               =   InfoCasting
    downCast _ (PaneC a)    =   case casting a of
                                    InfoCasting -> Just a
                                    _           -> Nothing

idDescrDescr :: [FieldDescription IdentifierDescr]
idDescrDescr = [
            mkField
            (paraName <<<- ParaName "Symbol"
                $ paraHorizontal <<<- ParaHorizontal StartHorizontal
                    $ emptyParams)
            identifierID
            (\ b a -> a{identifierID = b})
            stringEditor
    ,    mkField
            (paraName <<<- ParaName "Sort"
                $ paraHorizontal <<<- ParaHorizontal StopHorizontal
                    $ emptyParams)
            identifierTypeID
            (\b a -> a{identifierTypeID = b})
            (staticSelectionEditor allIdTypes)
    ,   mkField
            (paraName <<<- ParaName "Exported by" $ emptyParams)
            (\l -> map showPackModule (moduleIdID l))
            (\ b a -> a{moduleIdID = (map parsePackModule b)})
            multiselectionEditor
    ,   mkField
            (paraName  <<<- ParaName "Type" $ emptyParams)
            typeInfoID
            (\b a -> a{typeInfoID = b})
            multilineStringEditor]

{--    ,   mkField (emptyParams
            {paraName = Just "Documentation"})
            typeInfo
            (\b a -> a{typeInfo = b})
            multilineStringEditor--}

allIdTypes = [Function,Data,Newtype,Synonym,AbstractData,Constructor,Field,Class,ClassOp,Foreign]

initInfo :: PanePath -> Notebook -> IdentifierDescr -> GhfAction
initInfo panePath nb idDescr = do
    ghfR <- ask
    panes <- readGhf panes
    paneMap <- readGhf paneMap
    prefs <- readGhf prefs
    (pane,cids) <- lift $ do
            nbbox       <- hBoxNew False 0
            ibox        <- vBoxNew False 0
            bb          <- vButtonBoxNew
            buttonBoxSetLayout bb ButtonboxStart
            definitionB <- buttonNewWithLabel "Definition"
            moduB       <- buttonNewWithLabel "Module"
            usesB       <- buttonNewWithLabel "Uses"
            docuB       <- buttonNewWithLabel "Docu"
            boxPackStart bb definitionB PackNatural 0
            boxPackStart bb moduB PackNatural 0
            boxPackStart bb usesB PackNatural 0
            boxPackStart bb docuB PackNatural 0
            boxPackStart bb usesB PackNatural 0
            resList <- mapM (\ fd -> (fieldEditor fd) idDescr) idDescrDescr
            let (widgets, setInjs, getExts, notifiers) = unzip4 resList
            foldM_ (\ box (w,mbh)  ->
                case mbh of
                    Keep            ->  do  boxPackStart box w PackNatural 0
                                            return box
                    StartHorizontal ->  do  newBox  <- hBoxNew False 0
                                            boxPackStart box newBox PackNatural 0
                                            boxPackStart newBox w PackNatural 0
                                            return (castToBox newBox)
                    StopHorizontal  ->  do  boxPackStart box w PackNatural 0
                                            par <- widgetGetParent box
                                            case par of
                                                Nothing -> error "initInfo - no parent"
                                                Just p -> return (castToBox p))
                (castToBox ibox)
                (zip widgets (map (getParameter paraHorizontal . parameters)
                    idDescrDescr))
            boxPackStart nbbox ibox PackNatural 0
            boxPackEnd nbbox bb PackNatural 0
            --openType
            sw <- scrolledWindowNew Nothing Nothing
            scrolledWindowAddWithViewport sw nbbox
            scrolledWindowSetPolicy sw PolicyAutomatic PolicyAutomatic
            let info = GhfInfo sw setInjs getExts
            --mapM_ (\w -> widgetSetExtensionEvents w [ExtensionEventsAll]) widgets
            cids <- mapM
                (\w -> w `onFocus` --onFocusIn doesn't work here - why?
                    (\_ -> do   runReaderT (makeActive info) ghfR
                                return False))
                        widgets
            notebookPrependPage nb sw (paneName info)
            widgetShowAll sw
            return (info,cids)
    addPaneAdmin pane (BufConnections [] [] []) panePath
    lift $widgetGrabFocus (sw pane)
    lift $bringPaneToFront pane

makeInfoActive :: GhfInfo -> GhfAction
makeInfoActive info = do
    activatePane info (BufConnections[][][])

setInfo :: IdentifierDescr -> GhfM ()
setInfo identifierDescr = do
    panesST <- readGhf panes
    prefs   <- readGhf prefs
    layout  <- readGhf layout
    let infos = catMaybes $ map (downCast InfoCasting) $ Map.elems panesST
    if null infos || length infos > 1
        then do
            let pp  =  getStandardPanePath (infoPanePath prefs) layout
            lift $ message $ "panePath " ++ show pp
            nb      <- getNotebook pp
            initInfo pp nb identifierDescr
            panesST <- readGhf panes
            let logs = catMaybes $ map (downCast InfoCasting) $ Map.elems panesST
            if null logs || length logs > 1
                then error "Can't init info"
                else return ()
        else do
            let inj = injectors (head infos)
            mapM_ (\ a -> lift $ a identifierDescr)  inj
            lift $ bringPaneToFront (head infos)
            return ()

getInfo ::  GhfM (Maybe (IdentifierDescr))
getInfo = do
    panesST <- readGhf panes
    let infos = catMaybes $ map (downCast InfoCasting) $ Map.elems panesST
    if null infos || length infos > 1
        then return Nothing
        else do
            let ext = extractors (head infos)
            v <- lift $ extract getDefault ext
            return v
