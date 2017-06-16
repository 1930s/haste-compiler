{-# LANGUAGE FlexibleInstances, FlexibleContexts, GADTs, OverloadedStrings #-}
-- | Hash manipulation and callbacks.
module Haste.Hash (
    onHashChange, setHash, getHash
  ) where
import Haste.Prim.Foreign
import Control.Monad.IO.Class
import Haste.Prim
import Haste.Events.Core

-- | Register a callback to be run whenever the URL hash changes.
--   The first and second argument of the callback are the old and new and
--   hash respectively.
onHashChange :: MonadEvent m
              => (JSString -> JSString -> m ())
              -> m ()
onHashChange f = do
  f' <- mkHandler $ uncurry f
  firsthash <- getHash
  liftIO $ jsOnHashChange firsthash f'

jsOnHashChange :: JSString -> ((JSString, JSString) -> IO ()) -> IO ()
jsOnHashChange =
  ffi "(function(firsthash,cb){\
          \window.__old_hash = firsthash;\
          \window.onhashchange = function(e){\
            \var oldhash = window.__old_hash;\
            \var newhash = window.location.hash.split('#')[1] || '';\
            \window.__old_hash = newhash;\
            \cb([oldhash,newhash]);\
          \};\
       \})"

-- | Set the hash part of the current URL.
setHash :: MonadIO m => JSString -> m ()
setHash = liftIO . jsSetHash

jsSetHash :: JSString -> IO ()
jsSetHash = ffi "(function(h) {location.hash = '#'+h;})"

-- | Read the hash part of the current URL.
getHash :: MonadIO m => m JSString
getHash = liftIO jsGetHash

jsGetHash :: IO JSString
jsGetHash = ffi "(function() {return location.hash.substring(1);})"
