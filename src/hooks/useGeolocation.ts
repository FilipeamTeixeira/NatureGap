'use client';

import { useCallback, useEffect, useState } from 'react';

export interface GeolocationState {
  coordinates: [number, number] | null;
  accuracyM: number | null;
  loading: boolean;
  error: string | null;
  refresh: () => void;
}

export function useGeolocation(): GeolocationState {
  const [coordinates, setCoordinates] = useState<[number, number] | null>(null);
  const [accuracyM, setAccuracyM] = useState<number | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(() => {
    if (!('geolocation' in navigator)) {
      setError('GPS is not available in this browser');
      return;
    }

    setLoading(true);
    navigator.geolocation.getCurrentPosition(
      (position) => {
        setCoordinates([position.coords.longitude, position.coords.latitude]);
        setAccuracyM(position.coords.accuracy);
        setError(null);
        setLoading(false);
      },
      (geoError) => {
        setError(geoError.message || 'Unable to detect GPS location');
        setLoading(false);
      },
      { enableHighAccuracy: true, maximumAge: 15000, timeout: 12000 },
    );
  }, []);

  useEffect(() => {
    const timeout = window.setTimeout(refresh, 0);
    return () => window.clearTimeout(timeout);
  }, [refresh]);

  return { coordinates, accuracyM, loading, error, refresh };
}
