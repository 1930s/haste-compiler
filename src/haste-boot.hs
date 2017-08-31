{-# LANGUAGE CPP #-}
import Prelude hiding (read)
import qualified Data.ByteString.Lazy as BSL
import qualified Data.ByteString as BS
import Data.Version
import Data.List (foldl')
import Data.Maybe (fromJust)
import Codec.Compression.BZip
import Codec.Archive.Tar
import Haste.Environment
import Haste.Version
import Control.Shell
import Control.Shell.Concurrent
import Control.Shell.Download
import Data.Char (isDigit)
import Haste.Args
import System.Console.GetOpt
import GHC.Paths (libdir)
import System.Info (os)
import System.Directory (copyPermissions)

#if __GLASGOW_HASKELL__ < 800
ghcMajor = "7.10"
libDir = "ghc-7.10"
primVersion = "0.4.0.0"
#endif

logStr :: String -> Shell ()
logStr s = echo $ "[haste-boot] " ++ s

data HasteCabal = Download | Prebuilt FilePath | Source (Maybe FilePath) | Preinstalled

data Cfg = Cfg {
    getLibs               :: Bool,
    getClosure            :: Bool,
    useLocalLibs          :: Bool,
    tracePrimops          :: Bool,
    forceBoot             :: Bool,
    initialPortableBoot   :: Bool,
    getHasteCabal         :: HasteCabal,
    verbose               :: Bool
  }

defCfg :: Cfg
#ifdef PORTABLE
defCfg = Cfg {
    getLibs               = False,
    getClosure            = False,
    useLocalLibs          = False,
    tracePrimops          = False,
    forceBoot             = False,
    initialPortableBoot   = False,
    getHasteCabal         = Download,
    verbose               = False
  }
#else
defCfg = Cfg {
    getLibs               = True,
    getClosure            = True,
    useLocalLibs          = False,
    tracePrimops          = False,
    forceBoot             = False,
    initialPortableBoot   = False,
    getHasteCabal         = Download,
    verbose               = False
  }
#endif

devBoot :: Cfg -> Cfg
devBoot cfg = cfg {
    useLocalLibs          = True,
    forceBoot             = True,
    getClosure            = False,
    getHasteCabal         = Source Nothing
  }

setInitialPortableBoot :: Cfg -> Cfg
setInitialPortableBoot cfg = cfg {
    getLibs             = True,
    useLocalLibs        = True,
    forceBoot           = True,
    getClosure          = True,
    initialPortableBoot = True,
    getHasteCabal       = Download
  }

specs :: [OptDescr (Cfg -> Cfg)]
specs = [
#ifndef PORTABLE
      Option "" ["dev"]
           (NoArg devBoot) $
           "Boot Haste for development. Implies --force " ++
           "--local --no-closure --build-haste-cabal"
    , Option "" ["force"]
#else
      Option "" ["force"]
#endif
           (NoArg $ \cfg -> cfg {forceBoot = True}) $
           "Re-boot Haste even if already properly booted."
    , Option "" ["initial"]
           (NoArg setInitialPortableBoot) $
           "Prepare boot files for binary distribution. Should only ever " ++
           "be called by the release build scripts, never by users.\n" ++
           "Implies --local --force."
    , Option "" ["local"]
           (NoArg $ \cfg -> cfg {useLocalLibs = True}) $
           "Use libraries from source repository rather than " ++
           "downloading a matching set from the Internet. " ++
           "This is nearly always necessary when installing " ++
           "Haste from Git rather than from Hackage. " ++
           "When using --local, your current working directory " ++
           "must be the root of the Haste source tree."
    , Option "" ["no-closure"]
           (NoArg $ \cfg -> cfg {getClosure = False}) $
           "Don't download Closure compiler. You won't be able " ++
           "to use --opt-minify, unless you manually " ++
           "give hastec the path to compiler.jar."
    , Option "" ["download-haste-cabal"]
           (NoArg $ \cfg -> cfg {getHasteCabal = Download}) $
           "Download pre-built haste-cabal for your platform. " ++
           "This is the default behaviour."
    , Option "" ["no-haste-cabal"]
           (NoArg $ \cfg -> cfg {getHasteCabal = Preinstalled}) $
           "Use whatever haste-cabal is found on your path; it will not be copied."
    , Option "" ["with-haste-cabal"]
           (ReqArg (\f cfg -> cfg {getHasteCabal = Prebuilt f}) "FILE") $
           "Use FILE to provide haste-cabal. It will be copied into the " ++
           "Haste binary directory."
    , Option "" ["build-haste-cabal"]
           (OptArg (\md cfg -> cfg {getHasteCabal = Source md}) "DIR") $
           "Build haste-cabal from the source contained in DIR. " ++
           "If DIR is not specified, `../cabal/' is assumed."
    , Option "" ["no-libs"]
           (NoArg $ \cfg -> cfg {getLibs = False}) $
           "Don't install any libraries. This is probably not " ++
           "what you want."
    , Option "" ["trace-primops"]
           (NoArg $ \cfg -> cfg {tracePrimops = True}) $
           "Build standard libs for tracing of primitive " ++
           "operations. Only use if you're debugging the code " ++
           "generator."
    , Option "v" ["verbose"]
           (NoArg $ \cfg -> cfg {verbose = True}) $
           "Print absolutely everything."
  ]

hdr :: String
hdr = "Fetch, build and install all libraries necessary to use Haste.\n"

data CabalOp = Configure | Build | Install | Clean

main :: IO ()
main = shell_ $ do
  when ("--help" `elem` cmdline || "-?" `elem` cmdline) $ do
    echo $ printHelp hdr specs
    exit

  case getOpt Permute specs cmdline of
    (cfgs, [], []) -> do
      let cfg = foldl' (flip (.)) id cfgs defCfg
      when (hasteNeedsReboot || forceBoot cfg) $ do
        if useLocalLibs cfg
          then bootHaste cfg "."
          else withTempDirectory $ bootHaste cfg
    (cfgs, nopts, errs) -> do
      let errors = errs ++ map (\x -> "unrecognized option `" ++ x ++ "'") nopts
      fail $ unlines errors

bootHaste :: Cfg -> FilePath -> Shell ()
bootHaste cfg tmpdir =
  withEnv "nodosfilewarning" "1" . inDirectory tmpdir $ do
    removeBootFile <- isFile bootFile
    when removeBootFile $ rm bootFile
    when (getLibs cfg) $ do
      -- Don't clear dir when it contains binaries; portable should only be built
      -- by scripts anyway, so this dir ought to be clean.
      when (not portableHaste) $ do
        logStr "Removing old library directories"
        mapM_ clearDir [pkgUserLibDir, jsmodUserDir, pkgUserDir,
                        pkgSysLibDir, jsmodSysDir, pkgSysDir]

      mkdir True (hasteCabalRootDir portableHaste)
      case getHasteCabal cfg of
        Download     -> installHasteCabal portableHaste tmpdir
        Prebuilt fp  -> copyHasteCabal portableHaste fp
        Source mdir  -> buildHasteCabal portableHaste (maybe "../cabal" id mdir)
        Preinstalled -> return ()

      -- Spawn off closure download in the background.
      dir <- pwd -- use absolute path for closure to avoid dir changing race
      closure <- future $ when (getClosure cfg) (installClosure dir)

      -- Do a haste-cabal update before trying anything cabal related
      run hasteCabalBinary ["update"]

      when (not $ useLocalLibs cfg) $ do
        fetchLibs tmpdir

      when (not portableHaste || initialPortableBoot cfg) $ do
        logStr "Installing GHC settings"
        mkdir True hasteSysDir
        copyGhcSettings hasteSysDir
        run hastePkgBinary ["init", pkgSysDir]
        buildLibs cfg

      when (initialPortableBoot cfg) $ do
        logStr "Relocating libraries"
        mapM_ relocate ["array", "bytestring", "containers", "base",
                        "deepseq", "dlist", "haste-prim", "time", "haste-lib",
                        "monads-tf", "old-locale", "transformers", "integer-gmp",
                        "hashable", "text", "binary"]

      -- Wait for closure download to finish.
      await closure


    logStr "Creating boot file"
    output bootFile (showBootVersion bootVersion)
    logStr "All done!"

clearDir :: FilePath -> Shell ()
clearDir dir = do
  exists <- isDirectory dir
  when exists $ rmdir dir

copyHasteCabal :: Bool -> FilePath -> Shell ()
copyHasteCabal portable file = do
    mkdir True cabalDir
    cp file cabalBinary
    output (hasteBinDir </> "haste-cabal") (hasteCabalLauncher portable)
    liftIO $ copyPermissions cabalBinary (hasteBinDir </> "haste-cabal")
  where
    cabalDir = hasteCabalRootDir portable </> "haste-cabal"
    cabalBinary = cabalDir </> "haste-cabal.bin"

buildHasteCabal :: Bool -> FilePath -> Shell ()
buildHasteCabal portable dir = do
  inDirectory dir $ run "runghc" ["build-haste-cabal.hs"]
  copyHasteCabal portable (dir </> "haste-cabal" </> "haste-cabal.bin")

installHasteCabal :: Bool -> FilePath -> Shell ()
installHasteCabal portable tmpdir = do
    echo "Downloading haste-cabal from GitHub"
    f <- (decompress . BSL.fromChunks . (:[])) `fmap` fetchBytes hasteCabalUrl
    if os == "linux"
      then do
        liftIO . unpack rootdir $ read f
        liftIO $ copyPermissions
                    hasteBinary
                    (rootdir </> "haste-cabal/haste-cabal.bin")
        output (hasteBinDir </> hasteCabalFile) (hasteCabalLauncher portable)
      else do
        liftIO $ BSL.writeFile (hasteBinDir </> hasteCabalFile) f
    liftIO $ copyPermissions hasteBinary (hasteBinDir </> hasteCabalFile)
  where
    rootdir = hasteCabalRootDir portable
    baseUrl = "http://valderman.github.io/haste-libs/"
    hasteCabalUrl
      | os == "linux" = baseUrl ++ "haste-cabal.linux.tar.bz2"
      | otherwise     = baseUrl ++ "haste-cabal" <.> os <.> "bz2"
    hasteCabalFile = "haste-cabal" ++ if os == "mingw32" then ".exe" else ""

hasteCabalRootDir :: Bool -> FilePath
hasteCabalRootDir True  = hasteBinDir </> ".."
hasteCabalRootDir False = hasteSysDir

-- We need to determine the haste-cabal libdir at runtime if we're
-- portable
hasteCabalLauncher :: Bool -> String
hasteCabalLauncher True = unlines
  [ "#!/bin/bash"
  , "HASTEC=\"$(dirname $0)/hastec\""
  , "DIR=\"$($HASTEC --print-libdir)/../haste-cabal\""
  , "export LD_LIBRARY_PATH=$DIR"
  , "args=\"\""
  , "for arg in \"$@\" ; do"
  , "  args=\"$args \\\"$arg\\\"\""
  , "done"
  , "echo $args | xargs $DIR/haste-cabal.bin"
  ]
hasteCabalLauncher False = unlines
  [ "#!/bin/bash"
  , "DIR=\"" ++ hasteCabalRootDir False </> "haste-cabal" ++ "\""
  , "export LD_LIBRARY_PATH=$DIR"
  , "args=\"\""
  , "for arg in \"$@\" ; do"
  , "  args=\"$args \\\"$arg\\\"\""
  , "done"
  , "echo $args | xargs $DIR/haste-cabal.bin"
  ]

-- | Fetch the Haste base libs.
fetchLibs :: FilePath -> Shell ()
fetchLibs tmpdir = do
    logStr "Downloading base libs from GitHub"
    file <- fetchBytes $ mkUrl hasteVersion
    liftIO . unpack tmpdir . read . decompress $ BSL.fromChunks [file]
  where
    mkUrl v =
      "http://valderman.github.io/haste-libs/haste-libs-" ++ showVersion v ++ ".tar.bz2"

-- | Fetch and install the Closure compiler.
installClosure :: FilePath -> Shell ()
installClosure dir = do
    logStr "Downloading Google Closure compiler..."
    downloadClosure `orElse` do
      logStr "Couldn't install Closure compiler; continuing without."
  where
    downloadClosure = do
      fetchBytes closureURI >>= (liftIO . BS.writeFile (dir </> closureCompiler))
    closureURI =
      "http://valderman.github.io/haste-libs/compiler.jar"

-- | Build haste's base libs.
buildLibs :: Cfg -> Shell ()
buildLibs cfg = do
    -- Set up dirs and copy includes
    mkdir True $ pkgSysLibDir
    cpdir "include" hasteSysDir

    inDirectory ("utils" </> "unlit") $ do
      logStr "Building unlit"
      let out    = if os == "mingw32" then "unlit.exe" else "unlit"
          static = if os == "darwin" then [] else ["-static"]
          dash_s = if os == "darwin" then [] else ["-s"]
      run "gcc" (["-o" ++ out, "-O2", "unlit.c"]++static)
      run "strip" (dash_s ++ [out])
      cp out (hasteSysDir </> out)

    logStr "Setting up builtin_rts"
    run hastePkgBinary ["update", "--global", "libraries" </> "rts.pkg"]

    inDirectory "libraries" $ do
      logStr "Installing libraries"
      inDirectory libDir $ do
        -- Install ghc-prim
        inDirectory "ghc-prim" $ do
          logStr "Installing ghc-prim"
          hasteCabal Install ["--solver", "topdown"]

          -- To get the GHC.Prim module in spite of pretending to have
          -- build-type: Simple
          logStr "Patching ghc-prim package info"
          let osxprim = if os == "darwin" then "-osx" else ""
          run hastePkgBinary ["unregister", "--global","ghc-prim"]
          run hastePkgBinary ["update", "--global",
                               "ghc-prim-"++primVersion++osxprim++".conf"]

        -- Install integer-gmp; double install shouldn't be needed anymore.
        inDirectory "integer-gmp" $ do
          logStr "Installing integer-gmp"
          hasteCabal Install ["--solver", "topdown"]

        -- Install base
        inDirectory "base" $ do
          logStr "Installing base"
          hasteCabal Clean []
          hasteCabal Install ["--solver", "topdown", "-finteger-gmp"]

        -- Install array
        inDirectory "array" $ do
          logStr "Installing array"
          hasteCabal Clean []
          hasteCabal Install []

      -- Install haste-prim
      inDirectory "haste-prim" $ do
        logStr "Installing haste-prim"
        hasteCabal Install []

      -- Install time + hashable + haste-lib
      inDirectory "time" $ do
        logStr "Installing time"
        hasteCabal Install []

      logStr "Installing hashable + haste-lib"
      hasteCabal Install [ "hashable-1.2.4.0"
                         , "-f-integer-gmp"
                         , "-f-sse2"
                         , "-f-sse41"
                         , "./haste-lib"]

      -- Export monads-tf; it seems to be hidden by default
      logStr "Exposing monads-tf"
      run hastePkgBinary ["expose", "monads-tf"]
  where
    ghcOpts = concat [
        if tracePrimops cfg then ["--hastec-option=-debug"] else [],
        if verbose cfg then ["--verbose"] else []]
    configOpts = [ "--with-hastec=" ++ hasteBinary
                 , "--with-haste-pkg=" ++ hastePkgBinary
                 , "--libdir=" ++ if os == "darwin"
                                    then pkgSysLibDir
                                    else takeDirectory pkgSysLibDir
                 , "--package-db=clear"
                 , "--package-db=global"
                 , "--hastec-option=-fforce-recomp"
                 ]
    hasteCabal Configure args =
      withEnv "HASTE_BOOTING" "1" $ run hasteCabalBinary as
      where as = "configure" : args ++ ghcOpts ++ configOpts
    hasteCabal Install args =
      withEnv "HASTE_BOOTING" "1" $ run hasteCabalBinary as
      where as = "install" : args ++ ghcOpts ++ configOpts
    hasteCabal Build args =
      withEnv "HASTE_BOOTING" "1" $ run hasteCabalBinary as
      where as = "build" : args ++ ghcOpts
    hasteCabal Clean args =
      withEnv "HASTE_BOOTING" "1" $ run hasteCabalBinary as
      where as = "clean" : args

    vanillaCabal args = run "cabal" args


-- | Copy GHC settings and utils into the given directory.
copyGhcSettings :: FilePath -> Shell ()
copyGhcSettings dest = do
  cp (libdir </> "platformConstants") (dest </> "platformConstants")
#ifdef mingw32_HOST_OS
  cp ("settings-ghc-" ++ ghcMajor ++ ".windows") (dest </> "settings")
  cp (libdir </> "touchy.exe") (dest </> "touchy.exe")
#else
  cp (libdir </> "settings") (dest </> "settings")
#endif

relocate :: String -> Shell ()
relocate pkg = do
  logStr $ "Relocating " ++ pkg
  run hastePkgBinary ["relocate", pkg]
