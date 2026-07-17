'use client';

import { useCallback, useEffect, useState } from 'react';
import { AlertTriangle, Check, Inbox, MapPin, MessageSquare, X } from 'lucide-react';
import {
  fetchPendingSuggestions,
  fetchPendingSurveyPoints,
  fetchSurveysForReview,
  reviewSuggestion,
  reviewSurvey,
  reviewSurveyPoint,
  type AppRole,
  type PendingSuggestion,
  type PendingSurveyPoint,
  type ReviewSurveyItem,
} from '@/lib/citizen-science';
import { StatusMessage, formatTime } from './ui';

interface ReviewQueueProps {
  role: AppRole | null;
  onRefreshMapData: () => void;
}

const HABITAT_SUMMARY_KEYS: { key: string; label: string }[] = [
  { key: 'vegetation_height_variation', label: 'Vegetation' },
  { key: 'canopy_cover', label: 'Canopy' },
  { key: 'flower_richness', label: 'Flowers' },
  { key: 'water_presence', label: 'Water' },
  { key: 'invasive_species_presence', label: 'Invasive' },
];

export default function ReviewQueue({ role, onRefreshMapData }: ReviewQueueProps) {
  const isVerifier = role === 'taxonomist';
  const isApprover = role === 'admin';

  // Verifier acts on pending_verification; approver signs off verified surveys.
  const surveyStatus = isApprover ? 'verified' : 'pending_verification';

  const [surveys, setSurveys] = useState<ReviewSurveyItem[]>([]);
  const [points, setPoints] = useState<PendingSurveyPoint[]>([]);
  const [suggestions, setSuggestions] = useState<PendingSuggestion[]>([]);
  const [loading, setLoading] = useState(true);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [message, setMessage] = useState<{ kind: 'success' | 'error'; text: string } | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const [surveyRows, pointRows, suggestionRows] = await Promise.all([
        fetchSurveysForReview(surveyStatus),
        isApprover ? fetchPendingSurveyPoints() : Promise.resolve([]),
        isApprover ? fetchPendingSuggestions() : Promise.resolve([]),
      ]);
      setSurveys(surveyRows);
      setPoints(pointRows);
      setSuggestions(suggestionRows);
    } finally {
      setLoading(false);
    }
  }, [surveyStatus, isApprover]);

  useEffect(() => {
    let cancelled = false;
    const timeout = window.setTimeout(() => {
      load().catch(() => {
        if (!cancelled) setMessage({ kind: 'error', text: 'Could not load the review queue.' });
      });
    }, 0);
    return () => {
      cancelled = true;
      window.clearTimeout(timeout);
    };
  }, [load]);

  async function act(id: string, run: () => Promise<unknown>, successText: string) {
    setBusyId(id);
    setMessage(null);
    try {
      await run();
      setMessage({ kind: 'success', text: successText });
      await load();
      onRefreshMapData();
    } catch (error) {
      setMessage({ kind: 'error', text: error instanceof Error ? error.message : 'Action failed.' });
    } finally {
      setBusyId(null);
    }
  }

  if (!isVerifier && !isApprover) {
    return <StatusMessage kind="warning">Review tools are available to Verifier and Approver roles.</StatusMessage>;
  }

  const advanceLabel = isApprover ? 'Approve' : 'Verify';
  const empty =
    surveys.length === 0 && points.length === 0 && suggestions.length === 0;

  return (
    <div className="flex flex-col gap-4">
      <div className="bg-white border border-[#E4E7E1] rounded-lg p-4">
        <p className="text-[13px] font-medium text-[#1F2A1F]">
          {isApprover ? 'Approval queue' : 'Verification queue'}
        </p>
        <p className="text-[12px] text-[#667066] mt-1">
          {isApprover
            ? 'Verified surveys awaiting final sign-off, plus pending survey points and suggestions.'
            : 'Newly submitted surveys awaiting completeness and plausibility checks.'}
        </p>
      </div>

      {message && <StatusMessage kind={message.kind}>{message.text}</StatusMessage>}

      {loading ? (
        <StatusMessage kind="warning">Loading queue...</StatusMessage>
      ) : empty ? (
        <div className="bg-white border border-[#E4E7E1] rounded-lg p-6 flex flex-col items-center gap-2 text-center">
          <Inbox size={22} className="text-[#A8B4A8]" strokeWidth={1.6} />
          <p className="text-[13px] text-[#667066]">Nothing to review right now.</p>
        </div>
      ) : (
        <>
          {surveys.map((survey) => (
            <div key={survey.id} className="bg-white border border-[#E4E7E1] rounded-lg p-4 flex flex-col gap-3">
              <div className="flex items-center justify-between">
                <h3 className="text-[13px] font-semibold text-[#1F2A1F]">Structured survey</h3>
                <span className="text-[11px] text-[#667066]">{formatTime(survey.duration_seconds)}</span>
              </div>

              <div className="text-[12px] text-[#667066]">
                Cell {survey.cell_id ?? 'unknown'} ·{' '}
                {survey.submitted_at ? new Date(survey.submitted_at).toLocaleDateString() : 'not submitted'}
              </div>

              <div className="grid grid-cols-2 gap-x-3 gap-y-1 text-[12px]">
                {HABITAT_SUMMARY_KEYS.map(({ key, label }) => {
                  const value = survey.habitat_indicators[key];
                  const display = typeof value === 'boolean' ? (value ? 'yes' : 'no') : String(value ?? '—');
                  return (
                    <div key={key} className="flex justify-between gap-2">
                      <span className="text-[#8A948A]">{label}</span>
                      <span className="text-[#1F2A1F]">{display}</span>
                    </div>
                  );
                })}
              </div>

              {survey.records.length > 0 && (
                <div className="rounded-lg bg-[#F7F8F5] border border-[#E4E7E1] p-3 flex flex-col gap-1">
                  <p className="text-[11px] font-semibold text-[#667066] uppercase tracking-widest">Records</p>
                  {survey.records.map((record) => (
                    <div key={record.id} className="text-[12px] text-[#1F2A1F] flex justify-between gap-2">
                      <span>{record.species_label ?? `${record.taxon_group} (unidentified)`}</span>
                      <span className="text-[#667066]">×{record.count}</span>
                    </div>
                  ))}
                </div>
              )}

              {survey.flags.length > 0 && (
                <div className="flex flex-col gap-1">
                  {survey.flags.map((flag, index) => (
                    <div key={index} className="flex items-start gap-2 text-[11px] text-[#8A5B12]">
                      <AlertTriangle size={12} className="mt-0.5 flex-shrink-0" strokeWidth={1.8} />
                      <span>
                        {flag.reason} ({flag.outcome})
                      </span>
                    </div>
                  ))}
                </div>
              )}

              <div className="flex gap-2">
                <button
                  type="button"
                  disabled={busyId === survey.id}
                  onClick={() => act(survey.id, () => reviewSurvey(survey.id, 'advance'), `Survey ${advanceLabel.toLowerCase()}d.`)}
                  className="flex-1 h-9 rounded-lg bg-[#2E6F40] text-white text-[12px] font-semibold disabled:bg-[#D1D8CE] flex items-center justify-center gap-1.5"
                >
                  <Check size={13} strokeWidth={2} />
                  {advanceLabel}
                </button>
                <button
                  type="button"
                  disabled={busyId === survey.id}
                  onClick={() => act(survey.id, () => reviewSurvey(survey.id, 'reject'), 'Survey rejected.')}
                  className="flex-1 h-9 rounded-lg border border-[#E8B48E] text-[#9B4A1A] text-[12px] font-semibold disabled:opacity-50 flex items-center justify-center gap-1.5"
                >
                  <X size={13} strokeWidth={2} />
                  Reject
                </button>
              </div>
            </div>
          ))}

          {points.map((point) => (
            <div key={point.id} className="bg-white border border-[#E4E7E1] rounded-lg p-4 flex flex-col gap-3">
              <div className="flex items-center gap-2">
                <MapPin size={14} className="text-[#2E6F40]" strokeWidth={1.7} />
                <h3 className="text-[13px] font-semibold text-[#1F2A1F]">Survey point</h3>
              </div>
              <p className="text-[12px] text-[#667066]">
                {point.coordinates[1].toFixed(5)}, {point.coordinates[0].toFixed(5)}
              </p>
              <div className="flex gap-2">
                <button
                  type="button"
                  disabled={busyId === point.id}
                  onClick={() => act(point.id, () => reviewSurveyPoint(point.id, 'advance'), 'Survey point approved.')}
                  className="flex-1 h-9 rounded-lg bg-[#2E6F40] text-white text-[12px] font-semibold disabled:bg-[#D1D8CE] flex items-center justify-center gap-1.5"
                >
                  <Check size={13} strokeWidth={2} />
                  Approve
                </button>
                <button
                  type="button"
                  disabled={busyId === point.id}
                  onClick={() => act(point.id, () => reviewSurveyPoint(point.id, 'reject'), 'Survey point rejected.')}
                  className="flex-1 h-9 rounded-lg border border-[#E8B48E] text-[#9B4A1A] text-[12px] font-semibold disabled:opacity-50 flex items-center justify-center gap-1.5"
                >
                  <X size={13} strokeWidth={2} />
                  Reject
                </button>
              </div>
            </div>
          ))}

          {suggestions.map((suggestion) => (
            <div key={suggestion.id} className="bg-white border border-[#E4E7E1] rounded-lg p-4 flex flex-col gap-3">
              <div className="flex items-center gap-2">
                <MessageSquare size={14} className="text-[#2E6F40]" strokeWidth={1.7} />
                <h3 className="text-[13px] font-semibold text-[#1F2A1F] capitalize">
                  {suggestion.type.replace('_', ' ')} suggestion
                </h3>
              </div>
              {typeof suggestion.payload?.text === 'string' && (
                <p className="text-[12px] text-[#1F2A1F] leading-relaxed">{suggestion.payload.text}</p>
              )}
              <div className="flex gap-2">
                <button
                  type="button"
                  disabled={busyId === suggestion.id}
                  onClick={() => act(suggestion.id, () => reviewSuggestion(suggestion.id, 'approved'), 'Suggestion approved.')}
                  className="flex-1 h-9 rounded-lg bg-[#2E6F40] text-white text-[12px] font-semibold disabled:bg-[#D1D8CE] flex items-center justify-center gap-1.5"
                >
                  <Check size={13} strokeWidth={2} />
                  Approve
                </button>
                <button
                  type="button"
                  disabled={busyId === suggestion.id}
                  onClick={() => act(suggestion.id, () => reviewSuggestion(suggestion.id, 'needs_revision'), 'Marked as needs revision.')}
                  className="h-9 px-3 rounded-lg border border-[#F2D49B] text-[#8A5B12] text-[12px] font-semibold disabled:opacity-50"
                >
                  Revise
                </button>
                <button
                  type="button"
                  disabled={busyId === suggestion.id}
                  onClick={() => act(suggestion.id, () => reviewSuggestion(suggestion.id, 'rejected'), 'Suggestion rejected.')}
                  className="flex-1 h-9 rounded-lg border border-[#E8B48E] text-[#9B4A1A] text-[12px] font-semibold disabled:opacity-50 flex items-center justify-center gap-1.5"
                >
                  <X size={13} strokeWidth={2} />
                  Reject
                </button>
              </div>
            </div>
          ))}
        </>
      )}
    </div>
  );
}
