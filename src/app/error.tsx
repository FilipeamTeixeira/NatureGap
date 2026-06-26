'use client';

import { useEffect } from 'react';
import { AlertTriangle } from 'lucide-react';

export default function Error({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  useEffect(() => {
    console.error('[NatureGap] Unhandled render error:', error);
  }, [error]);

  return (
    <div className="h-full flex items-center justify-center bg-[#F7F8F5]">
      <div className="bg-white rounded-2xl border border-[#E4E7E1] p-8 max-w-md w-full text-center"
           style={{ boxShadow: '0 1px 2px rgba(0,0,0,0.03)' }}>
        <div className="w-12 h-12 bg-[#FDF0E4] rounded-2xl flex items-center justify-center mx-auto mb-4">
          <AlertTriangle size={20} className="text-[#E8A44C]" strokeWidth={1.5} />
        </div>
        <h2 className="text-[18px] font-semibold text-[#1F2A1F] mb-2">Something went wrong</h2>
        <p className="text-[13px] text-[#667066] leading-relaxed mb-6">
          An unexpected error occurred. Local data is still available — try reloading the page.
        </p>
        <button
          onClick={reset}
          className="bg-[#2E6F40] text-white text-[13px] font-medium px-5 py-2.5 rounded-xl hover:bg-[#265a34] transition-colors"
        >
          Try again
        </button>
        {error.digest && (
          <p className="text-[10px] text-[#A8B4A8] mt-4 font-mono">
            Error ID: {error.digest}
          </p>
        )}
      </div>
    </div>
  );
}
