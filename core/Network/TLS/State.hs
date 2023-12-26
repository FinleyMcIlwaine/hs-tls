{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE Rank2Types #-}

-- |
-- Module      : Network.TLS.State
-- License     : BSD-style
-- Maintainer  : Vincent Hanquez <vincent@snarc.org>
-- Stability   : experimental
-- Portability : unknown
--
-- the State module contains calls related to state initialization/manipulation
-- which is use by the Receiving module and the Sending module.
module Network.TLS.State (
    TLSState (..),
    TLSSt,
    runTLSState,
    newTLSState,
    withTLSRNG,
    setVerifyDataForSend,
    setVerifyDataForRecv,
    getVerifyData,
    getMyVerifyData,
    getPeerVerifyData,
    getFirstVerifyData,
    finishedHandshakeTypeMaterial,
    finishedHandshakeMaterial,
    certVerifyHandshakeTypeMaterial,
    certVerifyHandshakeMaterial,
    setVersion,
    setVersionIfUnset,
    getVersion,
    getVersionWithDefault,
    setSecureRenegotiation,
    getSecureRenegotiation,
    setExtensionALPN,
    getExtensionALPN,
    setNegotiatedProtocol,
    getNegotiatedProtocol,
    setClientALPNSuggest,
    getClientALPNSuggest,
    setClientEcPointFormatSuggest,
    getClientEcPointFormatSuggest,
    getClientCertificateChain,
    setClientCertificateChain,
    setClientSNI,
    getClientSNI,
    setSession,
    getSession,
    isSessionResuming,
    getRole,
    setExporterMasterSecret,
    getExporterMasterSecret,
    setTLS13KeyShare,
    getTLS13KeyShare,
    setTLS13PreSharedKey,
    getTLS13PreSharedKey,
    setTLS13HRR,
    getTLS13HRR,
    setTLS13Cookie,
    getTLS13Cookie,
    setClientSupportsPHA,
    getClientSupportsPHA,
    setTLS12SessionTicket,
    getTLS12SessionTicket,

    -- * random
    genRandom,
    withRNG,
) where

import Control.Monad.State.Strict
import Crypto.Random
import qualified Data.ByteString as B
import Data.X509 (CertificateChain)
import Network.TLS.ErrT
import Network.TLS.Extension
import Network.TLS.Imports
import Network.TLS.RNG
import Network.TLS.Struct
import Network.TLS.Types (HostName, Role (..), Ticket)
import Network.TLS.Wire (GetContinuation)

data TLSState = TLSState
    { stSession :: Session
    , stSessionResuming :: Bool
    , -- RFC 5746, Renegotiation Indication Extension
      -- RFC 5929, Channel Bindings for TLS, "tls-unique"
      stSecureRenegotiation :: Bool
    , stClientVerifyData :: Maybe VerifyData
    , stServerVerifyData :: Maybe VerifyData
    , -- RFC 5929, Channel Bindings for TLS, "tls-server-end-point"
      stServerEndPoint :: ByteString
    , stExtensionALPN :: Bool -- RFC 7301
    , stHandshakeRecordCont :: Maybe (GetContinuation (HandshakeType, ByteString))
    , stNegotiatedProtocol :: Maybe B.ByteString -- ALPN protocol
    , stHandshakeRecordCont13 :: Maybe (GetContinuation (HandshakeType, ByteString))
    , stClientALPNSuggest :: Maybe [B.ByteString]
    , stClientGroupSuggest :: Maybe [Group]
    , stClientEcPointFormatSuggest :: Maybe [EcPointFormat]
    , stClientCertificateChain :: Maybe CertificateChain
    , stClientSNI :: Maybe HostName
    , stRandomGen :: StateRNG
    , stVersion :: Maybe Version
    , stClientContext :: Role
    , stTLS13KeyShare :: Maybe KeyShare
    , stTLS13PreSharedKey :: Maybe PreSharedKey
    , stTLS13HRR :: Bool
    , stTLS13Cookie :: Maybe Cookie
    , stExporterMasterSecret :: Maybe ByteString -- TLS 1.3
    , stClientSupportsPHA :: Bool -- Post-Handshake Authentication (TLS 1.3)
    , stTLS12SessionTicket :: Maybe Ticket
    }

newtype TLSSt a = TLSSt {runTLSSt :: ErrT TLSError (State TLSState) a}
    deriving (Monad, MonadError TLSError, Functor, Applicative)

instance MonadState TLSState TLSSt where
    put x = TLSSt (lift $ put x)
    get = TLSSt (lift get)
    state f = TLSSt (lift $ state f)

runTLSState :: TLSSt a -> TLSState -> (Either TLSError a, TLSState)
runTLSState f st = runState (runErrT (runTLSSt f)) st

newTLSState :: StateRNG -> Role -> TLSState
newTLSState rng clientContext =
    TLSState
        { stSession = Session Nothing
        , stSessionResuming = False
        , stSecureRenegotiation = False
        , stClientVerifyData = Nothing
        , stServerVerifyData = Nothing
        , stServerEndPoint = ""
        , stExtensionALPN = False
        , stHandshakeRecordCont = Nothing
        , stHandshakeRecordCont13 = Nothing
        , stNegotiatedProtocol = Nothing
        , stClientALPNSuggest = Nothing
        , stClientGroupSuggest = Nothing
        , stClientEcPointFormatSuggest = Nothing
        , stClientCertificateChain = Nothing
        , stClientSNI = Nothing
        , stRandomGen = rng
        , stVersion = Nothing
        , stClientContext = clientContext
        , stTLS13KeyShare = Nothing
        , stTLS13PreSharedKey = Nothing
        , stTLS13HRR = False
        , stTLS13Cookie = Nothing
        , stExporterMasterSecret = Nothing
        , stClientSupportsPHA = False
        , stTLS12SessionTicket = Nothing
        }

setVerifyDataForSend :: VerifyData -> TLSSt ()
setVerifyDataForSend bs = do
    role <- getRole
    case role of
        ClientRole -> modify (\st -> st{stClientVerifyData = Just bs})
        ServerRole -> modify (\st -> st{stServerVerifyData = Just bs})

setVerifyDataForRecv :: VerifyData -> TLSSt ()
setVerifyDataForRecv bs = do
    role <- getRole
    case role of
        ClientRole -> modify (\st -> st{stServerVerifyData = Just bs})
        ServerRole -> modify (\st -> st{stClientVerifyData = Just bs})

finishedHandshakeTypeMaterial :: HandshakeType -> Bool
finishedHandshakeTypeMaterial HandshakeType_ClientHello = True
finishedHandshakeTypeMaterial HandshakeType_ServerHello = True
finishedHandshakeTypeMaterial HandshakeType_Certificate = True
finishedHandshakeTypeMaterial HandshakeType_HelloRequest = False
finishedHandshakeTypeMaterial HandshakeType_ServerHelloDone = True
finishedHandshakeTypeMaterial HandshakeType_ClientKeyXchg = True
finishedHandshakeTypeMaterial HandshakeType_ServerKeyXchg = True
finishedHandshakeTypeMaterial HandshakeType_CertRequest = True
finishedHandshakeTypeMaterial HandshakeType_CertVerify = True
finishedHandshakeTypeMaterial HandshakeType_Finished = False
finishedHandshakeTypeMaterial _ = True -- checkme

finishedHandshakeMaterial :: Handshake -> Bool
finishedHandshakeMaterial = finishedHandshakeTypeMaterial . typeOfHandshake

certVerifyHandshakeTypeMaterial :: HandshakeType -> Bool
certVerifyHandshakeTypeMaterial HandshakeType_ClientHello = True
certVerifyHandshakeTypeMaterial HandshakeType_ServerHello = True
certVerifyHandshakeTypeMaterial HandshakeType_Certificate = True
certVerifyHandshakeTypeMaterial HandshakeType_HelloRequest = False
certVerifyHandshakeTypeMaterial HandshakeType_ServerHelloDone = True
certVerifyHandshakeTypeMaterial HandshakeType_ClientKeyXchg = True
certVerifyHandshakeTypeMaterial HandshakeType_ServerKeyXchg = True
certVerifyHandshakeTypeMaterial HandshakeType_CertRequest = True
certVerifyHandshakeTypeMaterial HandshakeType_CertVerify = False
certVerifyHandshakeTypeMaterial HandshakeType_Finished = False
certVerifyHandshakeTypeMaterial _ = False -- checkme

certVerifyHandshakeMaterial :: Handshake -> Bool
certVerifyHandshakeMaterial = certVerifyHandshakeTypeMaterial . typeOfHandshake

setSession :: Session -> Bool -> TLSSt ()
setSession session resuming = modify (\st -> st{stSession = session, stSessionResuming = resuming})

getSession :: TLSSt Session
getSession = gets stSession

isSessionResuming :: TLSSt Bool
isSessionResuming = gets stSessionResuming

setVersion :: Version -> TLSSt ()
setVersion ver = modify (\st -> st{stVersion = Just ver})

setVersionIfUnset :: Version -> TLSSt ()
setVersionIfUnset ver = modify maybeSet
  where
    maybeSet st = case stVersion st of
        Nothing -> st{stVersion = Just ver}
        Just _ -> st

getVersion :: TLSSt Version
getVersion =
    fromMaybe (error "internal error: version hasn't been set yet")
        <$> gets stVersion

getVersionWithDefault :: Version -> TLSSt Version
getVersionWithDefault defaultVer = fromMaybe defaultVer <$> gets stVersion

setSecureRenegotiation :: Bool -> TLSSt ()
setSecureRenegotiation b = modify (\st -> st{stSecureRenegotiation = b})

getSecureRenegotiation :: TLSSt Bool
getSecureRenegotiation = gets stSecureRenegotiation

setExtensionALPN :: Bool -> TLSSt ()
setExtensionALPN b = modify (\st -> st{stExtensionALPN = b})

getExtensionALPN :: TLSSt Bool
getExtensionALPN = gets stExtensionALPN

setNegotiatedProtocol :: B.ByteString -> TLSSt ()
setNegotiatedProtocol s = modify (\st -> st{stNegotiatedProtocol = Just s})

getNegotiatedProtocol :: TLSSt (Maybe B.ByteString)
getNegotiatedProtocol = gets stNegotiatedProtocol

setClientALPNSuggest :: [B.ByteString] -> TLSSt ()
setClientALPNSuggest ps = modify (\st -> st{stClientALPNSuggest = Just ps})

getClientALPNSuggest :: TLSSt (Maybe [B.ByteString])
getClientALPNSuggest = gets stClientALPNSuggest

setClientEcPointFormatSuggest :: [EcPointFormat] -> TLSSt ()
setClientEcPointFormatSuggest epf = modify (\st -> st{stClientEcPointFormatSuggest = Just epf})

getClientEcPointFormatSuggest :: TLSSt (Maybe [EcPointFormat])
getClientEcPointFormatSuggest = gets stClientEcPointFormatSuggest

setClientCertificateChain :: CertificateChain -> TLSSt ()
setClientCertificateChain s = modify (\st -> st{stClientCertificateChain = Just s})

getClientCertificateChain :: TLSSt (Maybe CertificateChain)
getClientCertificateChain = gets stClientCertificateChain

setClientSNI :: HostName -> TLSSt ()
setClientSNI hn = modify (\st -> st{stClientSNI = Just hn})

getClientSNI :: TLSSt (Maybe HostName)
getClientSNI = gets stClientSNI

getVerifyData :: Role -> TLSSt ByteString
getVerifyData client = do
    mVerifyData <-
        gets (if client == ClientRole then stClientVerifyData else stServerVerifyData)
    return $ fromMaybe "" mVerifyData

getMyVerifyData :: TLSSt (Maybe ByteString)
getMyVerifyData = do
    role <- getRole
    if role == ClientRole
        then gets stClientVerifyData
        else gets stServerVerifyData

getPeerVerifyData :: TLSSt (Maybe ByteString)
getPeerVerifyData = do
    role <- getRole
    if role == ClientRole
        then gets stServerVerifyData
        else gets stClientVerifyData

getFirstVerifyData :: TLSSt (Maybe ByteString)
getFirstVerifyData = do
    resuming <- isSessionResuming
    if resuming
        then gets stServerVerifyData
        else gets stClientVerifyData

getRole :: TLSSt Role
getRole = gets stClientContext

genRandom :: Int -> TLSSt ByteString
genRandom n = do
    withRNG (getRandomBytes n)

withRNG :: MonadPseudoRandom StateRNG a -> TLSSt a
withRNG f = do
    st <- get
    let (a, rng') = withTLSRNG (stRandomGen st) f
    put (st{stRandomGen = rng'})
    return a

setExporterMasterSecret :: ByteString -> TLSSt ()
setExporterMasterSecret key = modify (\st -> st{stExporterMasterSecret = Just key})

getExporterMasterSecret :: TLSSt (Maybe ByteString)
getExporterMasterSecret = gets stExporterMasterSecret

setTLS13KeyShare :: Maybe KeyShare -> TLSSt ()
setTLS13KeyShare mks = modify (\st -> st{stTLS13KeyShare = mks})

getTLS13KeyShare :: TLSSt (Maybe KeyShare)
getTLS13KeyShare = gets stTLS13KeyShare

setTLS13PreSharedKey :: Maybe PreSharedKey -> TLSSt ()
setTLS13PreSharedKey mpsk = modify (\st -> st{stTLS13PreSharedKey = mpsk})

getTLS13PreSharedKey :: TLSSt (Maybe PreSharedKey)
getTLS13PreSharedKey = gets stTLS13PreSharedKey

setTLS13HRR :: Bool -> TLSSt ()
setTLS13HRR b = modify (\st -> st{stTLS13HRR = b})

getTLS13HRR :: TLSSt Bool
getTLS13HRR = gets stTLS13HRR

setTLS13Cookie :: Maybe Cookie -> TLSSt ()
setTLS13Cookie mcookie = modify (\st -> st{stTLS13Cookie = mcookie})

getTLS13Cookie :: TLSSt (Maybe Cookie)
getTLS13Cookie = gets stTLS13Cookie

setClientSupportsPHA :: Bool -> TLSSt ()
setClientSupportsPHA b = modify (\st -> st{stClientSupportsPHA = b})

getClientSupportsPHA :: TLSSt Bool
getClientSupportsPHA = gets stClientSupportsPHA

setTLS12SessionTicket :: Ticket -> TLSSt ()
setTLS12SessionTicket t = modify (\st -> st{stTLS12SessionTicket = Just t})

getTLS12SessionTicket :: TLSSt (Maybe Ticket)
getTLS12SessionTicket = gets stTLS12SessionTicket
