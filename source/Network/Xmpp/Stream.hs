{-# OPTIONS_HADDOCK hide #-}
{-# LANGUAGE NoMonomorphismRestriction, OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

module Network.Xmpp.Stream where

import           Control.Applicative ((<$>), (<*>))
import qualified Control.Exception as Ex
import           Control.Monad.Error
import           Control.Monad.Reader
import           Control.Monad.State.Strict

import qualified Data.ByteString as BS
import           Data.Conduit
import qualified Data.Conduit.Internal as DCI
import           Data.Conduit.List as CL
import           Data.Maybe (fromJust, isJust, isNothing)
import           Data.Text as Text
import           Data.Void (Void)
import           Data.XML.Pickle
import           Data.XML.Types

import           Network.Xmpp.Connection
import           Network.Xmpp.Errors
import           Network.Xmpp.Pickle
import           Network.Xmpp.Types

import           Text.Xml.Stream.Elements
import           Text.XML.Stream.Parse as XP

-- import Text.XML.Stream.Elements

-- Unpickles and returns a stream element. Throws a StreamXmlError on failure.
streamUnpickleElem :: PU [Node] a
                   -> Element
                   -> StreamSink a
streamUnpickleElem p x = do
    case unpickleElem p x of
        Left l -> throwError $ StreamOtherFailure -- TODO: Log: StreamXmlError (show l)
        Right r -> return r

-- This is the conduit sink that handles the stream XML events. We extend it
-- with ErrorT capabilities.
type StreamSink a = ErrorT StreamFailure (Pipe Event Event Void () IO) a

-- Discards all events before the first EventBeginElement.
throwOutJunk :: Monad m => Sink Event m ()
throwOutJunk = do
    next <- CL.peek
    case next of
        Nothing -> return () -- This will only happen if the stream is closed.
        Just (EventBeginElement _ _) -> return ()
        _ -> CL.drop 1 >> throwOutJunk

-- Returns an (empty) Element from a stream of XML events.
openElementFromEvents :: StreamSink Element
openElementFromEvents = do
    lift throwOutJunk
    hd <- lift CL.head
    case hd of
        Just (EventBeginElement name attrs) -> return $ Element name attrs []
        _ -> throwError $ StreamOtherFailure

-- Sends the initial stream:stream element and pulls the server features.
startStream :: StateT Connection_ IO (Either StreamFailure ())
startStream = runErrorT $ do
    state <- get
    -- Set the `to' attribute depending on the state of the connection.
    let from = case sConnectionState state of
                 ConnectionPlain -> if sJidWhenPlain state
                                        then sJid state else Nothing
                 ConnectionSecured -> sJid state
    case sHostname state of
        Nothing -> throwError StreamOtherFailure
        Just hostname -> lift $ do
            pushXmlDecl
            pushOpenElement $
                pickleElem xpStream ( "1.0"
                                    , from
                                    , Just (Jid Nothing hostname Nothing)
                                    , Nothing
                                    , sPreferredLang state
                                    )
    (lt, from, id, features) <- ErrorT . runEventsSink $ runErrorT $
                                streamS from
    modify (\s -> s{ sFeatures = features
                   , sStreamLang = Just lt
                   , sStreamId = id
                   , sFrom = from
                   } )
    return ()

-- Sets a new Event source using the raw source (of bytes)
-- and calls xmppStartStream.
restartStream :: StateT Connection_ IO (Either StreamFailure ())
restartStream = do
    raw <- gets (cRecv . cHand)
    let newSource = DCI.ResumableSource (loopRead raw $= XP.parseBytes def)
                                        (return ())
    modify (\s -> s{cEventSource = newSource })
    startStream
  where
    loopRead read = do
        bs <- liftIO (read 4096)
        if BS.null bs
            then return ()
            else yield bs >> loopRead read

-- Reads the (partial) stream:stream and the server features from the stream.
-- Also validates the stream element's attributes and throws an error if
-- appropriate.
-- TODO: from.
streamS :: Maybe Jid -> StreamSink ( LangTag
                                      , Maybe Jid
                                      , Maybe Text
                                      , ServerFeatures)
streamS expectedTo = do
    (from, to, id, langTag) <- xmppStreamHeader
    features <- xmppStreamFeatures
    return (langTag, from, id, features)
  where
    xmppStreamHeader :: StreamSink (Maybe Jid, Maybe Jid, Maybe Text.Text, LangTag)
    xmppStreamHeader = do
        lift throwOutJunk
        -- Get the stream:stream element (or whatever it is) from the server,
        -- and validate what we get.
        el <- openElementFromEvents
        case unpickleElem xpStream el of
            Left _  -> throwError StreamOtherFailure -- TODO: findStreamErrors el
            Right r -> validateData r

    validateData (_, _, _, _, Nothing) = throwError StreamOtherFailure -- StreamWrongLangTag Nothing
    validateData (ver, from, to, i, Just lang)
      | ver /= "1.0" = throwError StreamOtherFailure -- StreamWrongVersion (Just ver)
      | isJust to && to /= expectedTo = throwError StreamOtherFailure -- StreamWrongTo (Text.pack . show <$> to)
      | otherwise = return (from, to, i, lang)
    xmppStreamFeatures :: StreamSink ServerFeatures
    xmppStreamFeatures = do
        e <- lift $ elements =$ CL.head
        case e of
            Nothing -> liftIO $ Ex.throwIO StreamOtherFailure
            Just r -> streamUnpickleElem xpStreamFeatures r



xpStream :: PU [Node] (Text, Maybe Jid, Maybe Jid, Maybe Text, Maybe LangTag)
xpStream = xpElemAttrs
    (Name "stream" (Just "http://etherx.jabber.org/streams") (Just "stream"))
    (xp5Tuple
         (xpAttr "version" xpId)
         (xpAttrImplied "from" xpPrim)
         (xpAttrImplied "to" xpPrim)
         (xpAttrImplied "id" xpId)
         xpLangTag
    )

-- Pickler/Unpickler for the stream features - TLS, SASL, and the rest.
xpStreamFeatures :: PU [Node] ServerFeatures
xpStreamFeatures = xpWrap
    (\(tls, sasl, rest) -> SF tls (mbl sasl) rest)
    (\(SF tls sasl rest) -> (tls, lmb sasl, rest))
    (xpElemNodes
         (Name
             "features"
             (Just "http://etherx.jabber.org/streams")
             (Just "stream")
         )
         (xpTriple
              (xpOption pickleTlsFeature)
              (xpOption pickleSaslFeature)
              (xpAll xpElemVerbatim)
         )
    )
  where
    pickleTlsFeature :: PU [Node] Bool
    pickleTlsFeature = xpElemNodes "{urn:ietf:params:xml:ns:xmpp-tls}starttls"
        (xpElemExists "required")
    pickleSaslFeature :: PU [Node] [Text]
    pickleSaslFeature =  xpElemNodes
        "{urn:ietf:params:xml:ns:xmpp-sasl}mechanisms"
        (xpAll $ xpElemNodes
             "{urn:ietf:params:xml:ns:xmpp-sasl}mechanism" (xpContent xpId))
