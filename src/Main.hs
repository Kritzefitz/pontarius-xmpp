{-# LANGUAGE PackageImports, OverloadedStrings #-}
module Main where

import Data.Text as T

import Network.XMPP
import Network.XMPP.Concurrent
import Network.XMPP.Types
import Network
import GHC.IO.Handle
import Control.Concurrent
import Control.Concurrent.STM
import Control.Monad
import Control.Monad.Trans.State
import Control.Monad.IO.Class

philonous :: JID
philonous = read "uart14@species64739.dyndns.org"

attXmpp :: STM a -> XMPPThread a
attXmpp = liftIO . atomically

autoAccept :: XMPPThread ()
autoAccept = forever $ do
  st <- pullPresence
  case st of
    Presence from _ id (Just Subscribe) _ _ _ _  ->
      sendS . SPresence $
           Presence Nothing from id (Just Subscribed) Nothing Nothing Nothing []
    _ -> return ()

mirror :: XMPPThread ()
mirror = forever $ do
  st <- pullMessage
  case st of
    Message (Just from) _ id tp subject (Just bd) thr _ ->
      sendS . SMessage $
        Message Nothing from id tp subject
          (Just $ "you wrote: " `T.append` bd) thr []
    _ -> return ()


main :: IO ()
main = do
  sessionConnect "localhost" "species64739.dyndns.org" "bot" Nothing $ do
      singleThreaded $ xmppStartTLS exampleParams
      singleThreaded $ xmppSASL "pwd"
      singleThreaded $ xmppBind (Just "botsi")
      singleThreaded $ xmppSession
      forkXMPP autoAccept
      forkXMPP mirror
      sendS . SPresence $ Presence Nothing Nothing Nothing Nothing
                (Just Available) Nothing Nothing []
      sendS . SMessage $ Message Nothing philonous Nothing Nothing Nothing
        (Just "bla") Nothing []
      liftIO  . forever $ threadDelay 1000000
      return ()
  return ()

