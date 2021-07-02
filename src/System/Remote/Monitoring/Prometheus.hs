{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
module System.Remote.Monitoring.Prometheus
  ( toPrometheusRegistry
  , registerEKGStore
  , AdapterOptions(..)
  , labels
  , namespace
  , defaultOptions
  , updateMetrics
  ) where

import           Control.Monad
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Reader (runReaderT)
import Data.Foldable
import qualified Data.HashMap.Strict as HMap
import Data.Int
import qualified Data.Map.Strict as Map
import Lens.Micro.TH
import qualified Data.Text as T
import qualified System.Metrics as EKG
import qualified System.Metrics.Distribution as EKG
import qualified System.Metrics.Prometheus.Metric.Counter as Counter
import qualified System.Metrics.Prometheus.Metric.Gauge as Gauge
import qualified System.Metrics.Prometheus.MetricId as Prometheus
import qualified System.Metrics.Prometheus.Concurrent.Registry as Prometheus
import System.Metrics.Prometheus.Registry (RegistrySample)
import           System.Metrics.Prometheus.Concurrent.RegistryT (RegistryT(..))

--------------------------------------------------------------------------------
data AdapterOptions = AdapterOptions {
    _labels :: Prometheus.Labels
  , _namespace :: Maybe T.Text
  }

makeLenses ''AdapterOptions

--------------------------------------------------------------------------------
data Distribution = Distribution
  { meanG :: Gauge.Gauge
  , varianceG :: Gauge.Gauge
  , countC :: Counter.Counter
  , sumG :: Gauge.Gauge
  , minG :: Gauge.Gauge
  , maxG :: Gauge.Gauge
  }

data Metric =
    C Counter.Counter
  | G Gauge.Gauge
  | D Distribution

type MetricsMap = Map.Map Prometheus.Name Metric

--------------------------------------------------------------------------------
defaultOptions :: Prometheus.Labels -> AdapterOptions
defaultOptions l = AdapterOptions l Nothing

--------------------------------------------------------------------------------
registerEKGStore :: MonadIO m => EKG.Store -> AdapterOptions -> RegistryT m () -> m (IO RegistrySample)
registerEKGStore store opts registryAction = do
  (registry, mmap) <- liftIO $ toPrometheusRegistry' store opts
  runReaderT (unRegistryT registryAction) registry
  return (updateMetrics store opts mmap >> Prometheus.sample registry)

--------------------------------------------------------------------------------
toPrometheusRegistry' :: EKG.Store -> AdapterOptions -> IO (Prometheus.Registry, MetricsMap)
toPrometheusRegistry' store opts = do
  registry <- Prometheus.new
  samples <- EKG.sampleAll store
  mmap <- foldM (mkMetric opts registry) Map.empty (HMap.toList samples)
  return (registry, mmap)

--------------------------------------------------------------------------------
toPrometheusRegistry :: EKG.Store -> AdapterOptions -> IO Prometheus.Registry
toPrometheusRegistry store opts = fst <$> toPrometheusRegistry' store opts

--------------------------------------------------------------------------------
mkMetric :: AdapterOptions -> Prometheus.Registry -> MetricsMap -> (T.Text, EKG.Value) -> IO MetricsMap
mkMetric AdapterOptions{..} registry mmap (key, value) = do
  let k = mkKey _namespace key
  case value of
   EKG.Counter c -> do
     counter <- Prometheus.registerCounter k _labels registry
     Counter.add (fromIntegral c) counter
     return $! Map.insert k (C counter) $! mmap
   EKG.Gauge g   -> do
     gauge <- Prometheus.registerGauge k _labels registry
     Gauge.set (fromIntegral g) gauge
     return $! Map.insert k (G gauge) $! mmap
   EKG.Label _   -> return $! mmap
   EKG.Distribution stats -> do
     let statGauge name = do
           gauge <- Prometheus.registerGauge k ( Prometheus.addLabel "stat" name _labels) registry
           return gauge
     meanG <- statGauge "mean"
     varianceG <- statGauge"variance"
     countC <- Prometheus.registerCounter k (Prometheus.addLabel "stat" "count" _labels) registry
     sumG <- statGauge"sum"
     minG <- statGauge"min"
     maxG <- statGauge"max"
     let distribution = Distribution {..}
     updateDistribution distribution stats
     return $! Map.insert k (D Distribution {..}) mmap

updateDistribution :: Distribution -> EKG.Stats -> IO ()
updateDistribution Distribution{..} stats = do
  Gauge.set (EKG.mean stats) meanG
  Gauge.set (EKG.variance stats) varianceG
  Gauge.set (EKG.sum stats) sumG
  Gauge.set (EKG.min stats) minG
  Gauge.set (EKG.max stats) maxG
  updateCounter countC (EKG.count stats)

updateCounter :: Counter.Counter -> Int64 -> IO ()
updateCounter counter c = do
  (Counter.CounterSample oldCounterValue) <- Counter.sample counter
  let slack = c - fromIntegral oldCounterValue
  when (slack >= 0) $ Counter.add (fromIntegral slack) counter
--------------------------------------------------------------------------------
updateMetrics :: EKG.Store -> AdapterOptions -> MetricsMap -> IO ()
updateMetrics store opts mmap = do
  samples <- EKG.sampleAll store
  traverse_ (updateMetric opts mmap) (HMap.toList samples)

--------------------------------------------------------------------------------
mkKey :: Maybe T.Text -> T.Text -> Prometheus.Name
mkKey mbNs k =
  Prometheus.Name $ maybe mempty (<> "_") mbNs <> T.replace "." "_" k

--------------------------------------------------------------------------------
updateMetric :: AdapterOptions -> MetricsMap -> (T.Text, EKG.Value) -> IO ()
updateMetric AdapterOptions{..} mmap (key, value) = do
  let k = mkKey _namespace key
  case (Map.lookup k mmap, value) of
    -- TODO if we don't have a metric registered, register one
    (Just (C counter), EKG.Counter c)  -> updateCounter counter c
    (Just (G gauge),   EKG.Gauge g) -> Gauge.set (fromIntegral g) gauge
    (Just (D distribution), EKG.Distribution stats) -> updateDistribution distribution stats
    _ -> return ()
