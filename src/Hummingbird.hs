{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies      #-}
module Hummingbird
  ( loadConfig, runWithConfig ) where

import           Control.Concurrent
import           Control.Concurrent.Async
import           Control.Monad
import           Data.Aeson
import           Data.Default.Class
import           Data.String
import qualified Data.Text                      as T
import qualified Data.Text.Encoding             as T
import qualified Data.X509.CertificateStore     as X509
import           Network.MQTT.Authentication
import qualified Network.MQTT.Broker            as Broker
import           Network.MQTT.Message
import qualified Network.MQTT.Server            as Server
import qualified Network.Stack.Server           as SS
import qualified Network.TLS                    as TLS
import qualified Network.TLS.Extra.Cipher       as TLS
import           Options
import qualified System.Clock                   as Clock
import           System.Exit
import           System.IO
import qualified System.Log.Formatter           as LOG
import qualified System.Log.Handler             as LOG hiding (setLevel)
import qualified System.Log.Handler.Simple      as LOG
import qualified System.Log.Handler.Syslog      as LOG
import qualified System.Log.Logger              as LOG
import qualified System.Socket                  as S
import qualified System.Socket.Family.Inet      as S
import qualified System.Socket.Protocol.Default as S
import qualified System.Socket.Type.Stream      as S

import           Hummingbird.Configuration

data MainOptions = MainOptions
  { optConfigFilePath :: FilePath }

instance Options MainOptions where
  defineOptions = pure MainOptions
    <*> simpleOption "config" "settings.yaml" "Path to .yaml configuration file"

loadConfig :: FromJSON (AuthenticatorConfig auth) => IO (Config (AuthenticatorConfig auth))
loadConfig =
  runCommand $ \opts _-> do
    ec <- loadConfigFromFile (optConfigFilePath opts)
    case ec of
      Left e  -> hPutStrLn stderr e >> exitFailure
      Right c -> pure c

runWithConfig :: Authenticator auth => Config (AuthenticatorConfig auth) -> IO ()
runWithConfig conf = do
  LOG.removeAllHandlers
  LOG.updateGlobalLogger LOG.rootLoggerName (LOG.setLevel $ logLevel $ logging conf)
  forM_ (logAppenders $ logging conf) $ \appender->
   case appender of
     SyslogAppender  -> do
       s <- LOG.openlog "hummingbird" [LOG.PID] LOG.USER LOG.DEBUG
       LOG.updateGlobalLogger LOG.rootLoggerName (LOG.addHandler s)
     ConsoleAppender -> do
       lh <- LOG.streamHandler stderr LOG.DEBUG
       let h = LOG.setFormatter lh (LOG.simpleLogFormatter "[$time : $loggername : $prio] $msg")
       LOG.updateGlobalLogger LOG.rootLoggerName (LOG.addHandler h)
  LOG.infoM "hummingbird" "Started hummingbird MQTT message broker."
  authenticator <- newAuthenticator (auth conf)
  broker <- Broker.new authenticator
  void $ async (pingThread broker)
  forConcurrently_ (servers conf) (runServerWithConfig broker)

runServerWithConfig :: (Authenticator auth) => Broker.Broker auth -> ServerConfig -> IO ()
runServerWithConfig broker serverConfig = case serverConfig of
  SocketServer {} -> do
    cfg <- createSocketConfig serverConfig
    let mqttConfig = Server.MqttServerConfig {
        Server.mqttTransportConfig = cfg
      } :: SS.ServerConfig (Server.MQTT (S.Socket S.Inet S.Stream S.Default))
    runServerStack broker mqttConfig
  TlsServer {} -> do
    cfg <- createSecureSocketConfig serverConfig
    let mqttConfig = Server.MqttServerConfig {
        Server.mqttTransportConfig = cfg
      }
    runServerStack broker mqttConfig
  WebSocketServer socketConfig@SocketServer {} -> do
    cfg <- createSocketConfig socketConfig
    let mqttConfig = Server.MqttServerConfig {
      Server.mqttTransportConfig = SS.WebSocketServerConfig {
        SS.wsTransportConfig = cfg
      }
    }
    runServerStack broker mqttConfig
  WebSocketServer tlsConfig@TlsServer {} -> do
    cfg <- createSecureSocketConfig tlsConfig
    let mqttConfig = Server.MqttServerConfig {
      Server.mqttTransportConfig = SS.WebSocketServerConfig {
        SS.wsTransportConfig = cfg
      }
    }
    runServerStack broker mqttConfig
  _ -> error "Server stack not implemented."
  where
    createSocketConfig :: ServerConfig -> IO (SS.ServerConfig (S.Socket S.Inet S.Stream S.Default))
    createSocketConfig (SocketServer a p b) = do
      [addrinfo] <- S.getAddressInfo (Just $ T.encodeUtf8 a) (Just $ T.encodeUtf8 $ T.pack $ show p) (mconcat [S.aiNumericHost, S.aiNumericService]) :: IO [S.AddressInfo S.Inet S.Stream S.Default]
      pure SS.SocketServerConfig {
            SS.socketServerConfigBindAddress = S.socketAddress addrinfo
          , SS.socketServerConfigListenQueueSize = b
        }
    createSocketConfig _ = error "not a socket config"
    createSecureSocketConfig :: ServerConfig -> IO (SS.ServerConfig (SS.TLS (S.Socket S.Inet S.Stream S.Default)))
    createSecureSocketConfig (TlsServer tc cc ca crt key) = do
      mcs <- X509.readCertificateStore ca
      case mcs of
        Nothing -> do
          hPutStrLn stderr $ ca ++ ": cannot read/interpret."
          exitFailure
        Just cs -> do
          ecred <- TLS.credentialLoadX509 crt key
          case ecred of
            Left e -> error e
            Right credential -> do
              cfg <- createSocketConfig tc
              pure SS.TlsServerConfig {
                    SS.tlsTransportConfig = cfg
                  , SS.tlsServerParams    = def {
                      TLS.serverWantClientCert = cc
                    , TLS.serverCACertificates = X509.listCertificates cs
                    , TLS.serverShared = def {
                        TLS.sharedCredentials = TLS.Credentials [credential]
                      }
                    , TLS.serverSupported = def {
                        TLS.supportedVersions = [TLS.TLS12]
                      , TLS.supportedCiphers  = TLS.ciphersuite_all
                      }
                    }
                  }
    createSecureSocketConfig _ = error "not a tls config"

runServerStack :: (Authenticator auth, SS.StreamServerStack transport, Server.MqttServerTransportStack transport) => Broker.Broker auth -> SS.ServerConfig (Server.MQTT transport) -> IO ()
runServerStack broker stackConfig =
  SS.withServer stackConfig $ \server-> forever $ SS.withConnection server $ \connection info->
    Server.handleConnection broker connection info

pingThread :: Broker.Broker auth -> IO ()
pingThread broker = forM_ [0..] $ \uptime-> do
  threadDelay 1000000
  time <- Clock.sec <$> Clock.getTime Clock.Realtime
  Broker.publishUpstream' broker (uptimeMsg (uptime :: Int))
  Broker.publishUpstream' broker (unixtimeMsg time)
  where
    uptimeMsg uptime = Message "$SYS/uptime" (fromString $ show uptime) Qos0 False False
    unixtimeMsg time = Message "$SYS/unixtime" (fromString $ show time) Qos0 False False
