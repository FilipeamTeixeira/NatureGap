'use client';

import Link from 'next/link';
import { useEffect, useMemo, useState } from 'react';
import {
  AlertTriangle,
  Binoculars,
  Camera,
  CheckCircle2,
  Clock3,
  Crosshair,
  Leaf,
  Plus,
  Send,
  Timer,
} from 'lucide-react';
import { cn } from '@/lib/utils';
import { useGeolocation } from '@/hooks/useGeolocation';
import {
  addSurveyRecord,
  startStructuredSurvey,
  submitQuickSighting,
  submitSuggestion,
  submitStructuredSurvey,
  uploadCitizenPhoto,
  type AppRole,
  type HabitatIndicators,
  type SpeciesReferenceOption,
  type SuggestionType,
  type SurveyPointFeature,
  type TaxonGroup,
} from '@/lib/citizen-science';

type Mode = 'quick' | 'survey' | 'suggest';

const TAXON_GROUPS: { value: TaxonGroup; label: string }[] = [
  { value: 'bird', label: 'Bird' },
  { value: 'insect', label: 'Insect' },
  { value: 'plant', label: 'Plant' },
  { value: 'amphibian', label: 'Amphibian' },
  { value: 'other', label: 'Other' },
];

const EMPTY_HABITAT: HabitatIndicators = {
  vegetation_height_variation: 'mixed',
  canopy_cover: 'sparse',
  flower_richness: 0,
  dead_wood: false,
  litter_disturbance: 'low',
  invasive_species_presence: false,
  water_presence: 'none',
  light_pollution: 'low',
};

const SUGGESTION_TYPES: { value: SuggestionType; label: string }[] = [
  { value: 'survey_point', label: 'Survey point' },
  { value: 'species', label: 'Species' },
  { value: 'action', label: 'Action' },
  { value: 'habitat_photo', label: 'Habitat photo' },
  { value: 'local_note', label: 'Local knowledge' },
];

interface SurveyRecordDraft {
  taxon_group: TaxonGroup;
  species_id: string;
  count: number;
  notes: string;
  saved?: boolean;
}

interface CitizenSciencePanelProps {
  role: AppRole | null;
  species: SpeciesReferenceOption[];
  surveyPoints: SurveyPointFeature[];
  selectedSurveyPoint: SurveyPointFeature | null;
  onSelectSurveyPoint: (point: SurveyPointFeature | null) => void;
  onRefreshMapData: () => void;
}

function FieldLabel({ children }: { children: React.ReactNode }) {
  return <label className="text-[11px] font-semibold text-[#667066] uppercase tracking-widest">{children}</label>;
}

function StatusMessage({ kind, children }: { kind: 'success' | 'warning' | 'error'; children: React.ReactNode }) {
  const Icon = kind === 'success' ? CheckCircle2 : AlertTriangle;
  return (
    <div
      className={cn(
        'flex items-start gap-2 rounded-lg border px-3 py-2 text-[12px] leading-relaxed',
        kind === 'success' && 'bg-[#F2F8EF] border-[#CFE3C8] text-[#2E6F40]',
        kind === 'warning' && 'bg-[#FFF8E8] border-[#F2D49B] text-[#8A5B12]',
        kind === 'error' && 'bg-[#FDF0E4] border-[#E8B48E] text-[#9B4A1A]',
      )}
    >
      <Icon size={14} className="mt-0.5 flex-shrink-0" strokeWidth={1.8} />
      <span>{children}</span>
    </div>
  );
}

function Select({
  value,
  onChange,
  children,
}: {
  value: string;
  onChange: (value: string) => void;
  children: React.ReactNode;
}) {
  return (
    <select
      value={value}
      onChange={(event) => onChange(event.target.value)}
      className="w-full rounded-lg border border-[#E4E7E1] bg-white px-3 py-2 text-[13px] text-[#1F2A1F] outline-none focus:border-[#2E6F40]"
    >
      {children}
    </select>
  );
}

function formatTime(seconds: number): string {
  const mm = Math.floor(seconds / 60).toString().padStart(2, '0');
  const ss = Math.max(0, seconds % 60).toString().padStart(2, '0');
  return `${mm}:${ss}`;
}

export default function CitizenSciencePanel({
  role,
  species,
  surveyPoints,
  selectedSurveyPoint,
  onSelectSurveyPoint,
  onRefreshMapData,
}: CitizenSciencePanelProps) {
  const gps = useGeolocation();
  const [mode, setMode] = useState<Mode>('quick');
  const [quickTaxon, setQuickTaxon] = useState<TaxonGroup>('bird');
  const [quickSpeciesId, setQuickSpeciesId] = useState('');
  const [quickPhoto, setQuickPhoto] = useState<File | null>(null);
  const [quickBusy, setQuickBusy] = useState(false);
  const [quickMessage, setQuickMessage] = useState<{ kind: 'success' | 'error'; text: string } | null>(null);

  const [activeSurvey, setActiveSurvey] = useState<{ id: string; startedAt: string } | null>(null);
  const [elapsed, setElapsed] = useState(0);
  const [habitat, setHabitat] = useState<HabitatIndicators>(EMPTY_HABITAT);
  const [invasivePhoto, setInvasivePhoto] = useState<File | null>(null);
  const [records, setRecords] = useState<SurveyRecordDraft[]>([
    { taxon_group: 'bird', species_id: '', count: 1, notes: '' },
  ]);
  const [surveyBusy, setSurveyBusy] = useState(false);
  const [surveyMessage, setSurveyMessage] = useState<{ kind: 'success' | 'error' | 'warning'; text: string } | null>(null);
  const [suggestionType, setSuggestionType] = useState<SuggestionType>('local_note');
  const [suggestionText, setSuggestionText] = useState('');
  const [suggestionBusy, setSuggestionBusy] = useState(false);
  const [suggestionMessage, setSuggestionMessage] = useState<{ kind: 'success' | 'error'; text: string } | null>(null);

  const canSurvey = role === 'surveyor' || role === 'admin';
  const canQuick = role === 'contributor' || role === 'admin';
  const selectedSpecies = species.filter((item) => item.taxon_group === quickTaxon);
  const hasAuth = role !== null;

  useEffect(() => {
    if (!activeSurvey) return;
    const tick = () => {
      setElapsed(Math.max(0, Math.floor((Date.now() - new Date(activeSurvey.startedAt).getTime()) / 1000)));
    };
    tick();
    const interval = window.setInterval(tick, 1000);
    return () => window.clearInterval(interval);
  }, [activeSurvey]);

  const nearestSurveyPoint = useMemo(() => {
    if (selectedSurveyPoint || surveyPoints.length === 0 || !gps.coordinates) return null;
    const [lng, lat] = gps.coordinates;
    return surveyPoints
      .map((point) => ({
        point,
        distance: Math.hypot(point.coordinates[0] - lng, point.coordinates[1] - lat),
      }))
      .sort((a, b) => a.distance - b.distance)[0]?.point ?? null;
  }, [gps.coordinates, selectedSurveyPoint, surveyPoints]);

  async function handleQuickSubmit() {
    setQuickMessage(null);
    if (!gps.coordinates || gps.accuracyM == null) {
      setQuickMessage({ kind: 'error', text: 'GPS location is required before submitting.' });
      return;
    }

    setQuickBusy(true);
    try {
      const photoUrl = quickPhoto ? await uploadCitizenPhoto(quickPhoto, 'quick-sightings') : null;
      const [lng, lat] = gps.coordinates;
      const result = await submitQuickSighting({
        taxon_group: quickTaxon,
        species_id: quickSpeciesId || null,
        photo_url: photoUrl,
        lng,
        lat,
        gps_accuracy_m: gps.accuracyM,
      });
      setQuickMessage({
        kind: 'success',
        text: `Sighting submitted (${result.quick_sighting.status.replace('-', ' ')}).`,
      });
      setQuickPhoto(null);
      onRefreshMapData();
    } catch (error) {
      setQuickMessage({ kind: 'error', text: error instanceof Error ? error.message : 'Submission failed.' });
    } finally {
      setQuickBusy(false);
    }
  }

  async function handleStartSurvey() {
    const point = selectedSurveyPoint ?? nearestSurveyPoint;
    if (!point) {
      setSurveyMessage({ kind: 'error', text: 'Select an approved survey point on the map first.' });
      return;
    }

    setSurveyBusy(true);
    setSurveyMessage(null);
    try {
      const result = await startStructuredSurvey(point.id);
      setActiveSurvey({ id: result.structured_survey.id, startedAt: result.structured_survey.started_at });
      onSelectSurveyPoint(point);
      setSurveyMessage({ kind: 'success', text: 'Survey started.' });
    } catch (error) {
      setSurveyMessage({ kind: 'error', text: error instanceof Error ? error.message : 'Could not start survey.' });
    } finally {
      setSurveyBusy(false);
    }
  }

  async function handleSaveRecord(index: number) {
    if (!activeSurvey) return;
    const record = records[index];
    setSurveyBusy(true);
    setSurveyMessage(null);
    try {
      await addSurveyRecord({
        survey_id: activeSurvey.id,
        taxon_group: record.taxon_group,
        species_id: record.species_id || null,
        count: record.count,
        notes: record.notes || null,
      });
      setRecords((prev) => prev.map((item, i) => (i === index ? { ...item, saved: true } : item)));
      setSurveyMessage({ kind: 'success', text: 'Survey record saved.' });
      onRefreshMapData();
    } catch (error) {
      setSurveyMessage({ kind: 'error', text: error instanceof Error ? error.message : 'Could not save record.' });
    } finally {
      setSurveyBusy(false);
    }
  }

  async function handleSubmitSurvey() {
    if (!activeSurvey) return;
    if (elapsed < 15 * 60) {
      setSurveyMessage({ kind: 'warning', text: 'Survey submission unlocks after 15 minutes.' });
      return;
    }
    if (habitat.invasive_species_presence && !invasivePhoto && !habitat.invasive_species_photo_url) {
      setSurveyMessage({ kind: 'error', text: 'Invasive species presence requires a photo.' });
      return;
    }

    setSurveyBusy(true);
    setSurveyMessage(null);
    try {
      const unsavedRecords = records.filter((item) => !item.saved);
      for (const record of unsavedRecords) {
        await addSurveyRecord({
          survey_id: activeSurvey.id,
          taxon_group: record.taxon_group,
          species_id: record.species_id || null,
          count: record.count,
          notes: record.notes || null,
        });
      }
      if (unsavedRecords.length > 0) {
        setRecords((prev) => prev.map((item) => ({ ...item, saved: true })));
      }

      const invasiveUrl = invasivePhoto ? await uploadCitizenPhoto(invasivePhoto, 'habitat-indicators') : habitat.invasive_species_photo_url;
      const result = await submitStructuredSurvey(activeSurvey.id, {
        ...habitat,
        invasive_species_photo_url: habitat.invasive_species_presence ? invasiveUrl : undefined,
      }, {
        gps_accuracy_m: gps.accuracyM,
        gps_available: Boolean(gps.coordinates),
        elapsed_seconds_client: elapsed,
        survey_record_count: records.length,
      });
      setSurveyMessage({
        kind: 'success',
        text: `Survey submitted (${formatTime(result.structured_survey.duration_seconds)}).`,
      });
      setActiveSurvey(null);
      setElapsed(0);
      setHabitat(EMPTY_HABITAT);
      setInvasivePhoto(null);
      setRecords([{ taxon_group: 'bird', species_id: '', count: 1, notes: '' }]);
      onRefreshMapData();
    } catch (error) {
      setSurveyMessage({ kind: 'error', text: error instanceof Error ? error.message : 'Could not submit survey.' });
    } finally {
      setSurveyBusy(false);
    }
  }

  async function handleSuggestionSubmit() {
    setSuggestionMessage(null);
    if (!suggestionText.trim()) {
      setSuggestionMessage({ kind: 'error', text: 'Add a short suggestion before submitting.' });
      return;
    }

    setSuggestionBusy(true);
    try {
      const coordinates = gps.coordinates
        ? { lng: gps.coordinates[0], lat: gps.coordinates[1], gps_accuracy_m: gps.accuracyM }
        : {};
      const result = await submitSuggestion({
        type: suggestionType,
        payload: {
          text: suggestionText.trim(),
          selected_survey_point_id: selectedSurveyPoint?.id ?? null,
          ...coordinates,
        },
      });
      setSuggestionMessage({ kind: 'success', text: `Suggestion submitted (${result.suggestion.status}).` });
      setSuggestionText('');
    } catch (error) {
      setSuggestionMessage({ kind: 'error', text: error instanceof Error ? error.message : 'Could not submit suggestion.' });
    } finally {
      setSuggestionBusy(false);
    }
  }

  return (
    <div className="w-[440px] flex-shrink-0 bg-[#F7F8F5] border-l border-[#E4E7E1] flex flex-col overflow-hidden">
      <div className="bg-white border-b border-[#E4E7E1] px-5 py-4">
        <div className="flex items-center justify-between gap-3">
          <div>
            <h2 className="text-[16px] font-semibold text-[#1F2A1F]">Citizen science</h2>
            <p className="text-[12px] text-[#667066] mt-0.5">
              {role ? `${role.charAt(0).toUpperCase()}${role.slice(1)} access` : 'Sign in to contribute'}
            </p>
          </div>
          <div className="flex rounded-lg border border-[#E4E7E1] bg-[#F7F8F5] p-1">
            <button
              type="button"
              onClick={() => setMode('quick')}
              className={cn('px-3 py-1.5 rounded-md text-[12px] font-medium', mode === 'quick' ? 'bg-white text-[#1F2A1F] shadow-sm' : 'text-[#667066]')}
            >
              Quick
            </button>
            <button
              type="button"
              onClick={() => setMode('survey')}
              className={cn('px-3 py-1.5 rounded-md text-[12px] font-medium', mode === 'survey' ? 'bg-white text-[#1F2A1F] shadow-sm' : 'text-[#667066]')}
            >
              Survey
            </button>
            <button
              type="button"
              onClick={() => setMode('suggest')}
              className={cn('px-3 py-1.5 rounded-md text-[12px] font-medium', mode === 'suggest' ? 'bg-white text-[#1F2A1F] shadow-sm' : 'text-[#667066]')}
            >
              Suggest
            </button>
          </div>
        </div>
      </div>

      <div className="flex-1 overflow-y-auto p-5 flex flex-col gap-4">
        {!hasAuth && (
          <StatusMessage kind="warning">
            <Link href="/login" className="font-semibold underline underline-offset-2">
              Sign in
            </Link>
            {' '}to submit sightings and surveys.
          </StatusMessage>
        )}

        <div className="bg-white border border-[#E4E7E1] rounded-lg p-4">
          <div className="flex items-start justify-between gap-3">
            <div className="flex items-start gap-3">
              <div className="w-8 h-8 rounded-lg bg-[#DDEAD8] flex items-center justify-center">
                <Crosshair size={15} className="text-[#2E6F40]" strokeWidth={1.7} />
              </div>
              <div>
                <p className="text-[13px] font-medium text-[#1F2A1F]">GPS location</p>
                <p className="text-[12px] text-[#667066] mt-1">
                  {gps.coordinates ? `${gps.coordinates[1].toFixed(5)}, ${gps.coordinates[0].toFixed(5)}` : gps.loading ? 'Detecting...' : 'Unavailable'}
                </p>
                {gps.accuracyM != null && (
                  <p className={cn('text-[11px] mt-1', gps.accuracyM > 25 ? 'text-[#B07A2A]' : 'text-[#667066]')}>
                    Accuracy {Math.round(gps.accuracyM)}m
                  </p>
                )}
              </div>
            </div>
            <button
              type="button"
              onClick={gps.refresh}
              className="text-[11px] font-medium text-[#2E6F40] hover:underline"
            >
              Refresh
            </button>
          </div>
          {gps.error && <p className="text-[11px] text-[#9B4A1A] mt-3">{gps.error}</p>}
          {gps.accuracyM != null && gps.accuracyM > 25 && (
            <div className="mt-3">
              <StatusMessage kind="warning">GPS accuracy is above 25m. The record can be submitted, but it may be flagged for review.</StatusMessage>
            </div>
          )}
        </div>

        {mode === 'quick' ? (
          <div className="bg-white border border-[#E4E7E1] rounded-lg p-4 flex flex-col gap-4">
            <div className="flex items-center gap-2">
              <Binoculars size={15} className="text-[#2E6F40]" strokeWidth={1.7} />
              <h3 className="text-[14px] font-semibold text-[#1F2A1F]">Quick sighting</h3>
            </div>

            {!canQuick && hasAuth && (
              <StatusMessage kind="warning">Your role cannot submit quick sightings.</StatusMessage>
            )}

            <div className="flex flex-col gap-2">
              <FieldLabel>Taxon group</FieldLabel>
              <div className="grid grid-cols-2 gap-2">
                {TAXON_GROUPS.map((group) => (
                  <button
                    key={group.value}
                    type="button"
                    onClick={() => { setQuickTaxon(group.value); setQuickSpeciesId(''); }}
                    className={cn(
                      'rounded-lg border px-3 py-2 text-[12px] font-medium text-left',
                      quickTaxon === group.value ? 'border-[#2E6F40] bg-[#F2F8EF] text-[#2E6F40]' : 'border-[#E4E7E1] text-[#667066]',
                    )}
                  >
                    {group.label}
                  </button>
                ))}
              </div>
            </div>

            <div className="flex flex-col gap-2">
              <FieldLabel>Species</FieldLabel>
              <Select value={quickSpeciesId} onChange={setQuickSpeciesId}>
                <option value="">Unknown species</option>
                {selectedSpecies.map((item) => (
                  <option key={item.id} value={item.id}>
                    {item.common_name} ({item.scientific_name})
                  </option>
                ))}
              </Select>
            </div>

            <div className="flex flex-col gap-2">
              <FieldLabel>Photo</FieldLabel>
              {quickSpeciesId && selectedSpecies.find((item) => item.id === quickSpeciesId)?.requires_photo_on_first_record && (
                <p className="text-[11px] text-[#8A5B12]">First record of this species in a cell requires a photo.</p>
              )}
              <label className="flex items-center gap-3 rounded-lg border border-dashed border-[#D1D8CE] px-3 py-3 text-[12px] text-[#667066] cursor-pointer hover:border-[#2E6F40]">
                <Camera size={14} strokeWidth={1.7} />
                <span className="truncate">{quickPhoto ? quickPhoto.name : 'Attach optional photo'}</span>
                <input
                  type="file"
                  accept="image/*"
                  className="hidden"
                  onChange={(event) => setQuickPhoto(event.target.files?.[0] ?? null)}
                />
              </label>
            </div>

            {quickMessage && <StatusMessage kind={quickMessage.kind}>{quickMessage.text}</StatusMessage>}

            <button
              type="button"
              disabled={!canQuick || !hasAuth || quickBusy || !gps.coordinates || gps.accuracyM == null}
              onClick={handleQuickSubmit}
              className="h-10 rounded-lg bg-[#2E6F40] text-white text-[13px] font-semibold disabled:bg-[#D1D8CE] disabled:text-white flex items-center justify-center gap-2"
            >
              <Send size={14} strokeWidth={1.8} />
              {quickBusy ? 'Submitting...' : 'Submit sighting'}
            </button>
          </div>
        ) : mode === 'survey' ? (
          <div className="flex flex-col gap-4">
            {!canSurvey && hasAuth && (
              <StatusMessage kind="warning">Survey tools are available to Surveyor and Admin roles.</StatusMessage>
            )}

            <div className="bg-white border border-[#E4E7E1] rounded-lg p-4 flex flex-col gap-4">
              <div className="flex items-center gap-2">
                <Timer size={15} className="text-[#2E6F40]" strokeWidth={1.7} />
                <h3 className="text-[14px] font-semibold text-[#1F2A1F]">Structured survey</h3>
              </div>

              <div className="rounded-lg bg-[#F7F8F5] border border-[#E4E7E1] p-3">
                <p className="text-[11px] font-semibold text-[#667066] uppercase tracking-widest mb-1">Survey point</p>
                <p className="text-[13px] text-[#1F2A1F]">
                  {(selectedSurveyPoint ?? nearestSurveyPoint)?.id ?? 'Select an approved point on the map'}
                </p>
              </div>

              <div className="flex items-center justify-between rounded-lg bg-white border border-[#E4E7E1] px-4 py-3">
                <div className="flex items-center gap-2">
                  <Clock3 size={15} className="text-[#667066]" strokeWidth={1.7} />
                  <span className="text-[13px] font-semibold text-[#1F2A1F]">{formatTime(elapsed)}</span>
                </div>
                <span className="text-[11px] text-[#667066]">Target 15:00</span>
              </div>

              {!activeSurvey ? (
                <button
                  type="button"
                  disabled={!canSurvey || !hasAuth || surveyBusy || !(selectedSurveyPoint ?? nearestSurveyPoint)}
                  onClick={handleStartSurvey}
                  className="h-10 rounded-lg bg-[#2E6F40] text-white text-[13px] font-semibold disabled:bg-[#D1D8CE]"
                >
                  {surveyBusy ? 'Starting...' : 'Start survey'}
                </button>
              ) : (
                <StatusMessage kind={elapsed >= 15 * 60 ? 'success' : 'warning'}>
                  {elapsed >= 15 * 60 ? 'Submission unlocked.' : `Submission unlocks in ${formatTime(15 * 60 - elapsed)}.`}
                </StatusMessage>
              )}
            </div>

            {activeSurvey && (
              <>
                <div className="bg-white border border-[#E4E7E1] rounded-lg p-4 flex flex-col gap-4">
                  <div className="flex items-center gap-2">
                    <Leaf size={15} className="text-[#2E6F40]" strokeWidth={1.7} />
                    <h3 className="text-[14px] font-semibold text-[#1F2A1F]">Habitat indicators</h3>
                  </div>

                  <div className="grid grid-cols-2 gap-3">
                    <div className="flex flex-col gap-2">
                      <FieldLabel>Vegetation</FieldLabel>
                      <Select value={habitat.vegetation_height_variation} onChange={(value) => setHabitat((h) => ({ ...h, vegetation_height_variation: value as HabitatIndicators['vegetation_height_variation'] }))}>
                        {['uniform mown', 'mixed', 'tall grass', 'scrub'].map((value) => <option key={value}>{value}</option>)}
                      </Select>
                    </div>
                    <div className="flex flex-col gap-2">
                      <FieldLabel>Canopy</FieldLabel>
                      <Select value={habitat.canopy_cover} onChange={(value) => setHabitat((h) => ({ ...h, canopy_cover: value as HabitatIndicators['canopy_cover'] }))}>
                        {['none', 'sparse', 'moderate', 'dense'].map((value) => <option key={value}>{value}</option>)}
                      </Select>
                    </div>
                    <div className="flex flex-col gap-2">
                      <FieldLabel>Flowers</FieldLabel>
                      <input
                        type="number"
                        min={0}
                        value={habitat.flower_richness}
                        onChange={(event) => setHabitat((h) => ({ ...h, flower_richness: Number(event.target.value) }))}
                        className="rounded-lg border border-[#E4E7E1] px-3 py-2 text-[13px] outline-none focus:border-[#2E6F40]"
                      />
                    </div>
                    <div className="flex flex-col gap-2">
                      <FieldLabel>Dead wood</FieldLabel>
                      <Select value={habitat.dead_wood ? 'yes' : 'no'} onChange={(value) => setHabitat((h) => ({ ...h, dead_wood: value === 'yes' }))}>
                        <option value="no">no</option>
                        <option value="yes">yes</option>
                      </Select>
                    </div>
                    <div className="flex flex-col gap-2">
                      <FieldLabel>Litter</FieldLabel>
                      <Select value={habitat.litter_disturbance} onChange={(value) => setHabitat((h) => ({ ...h, litter_disturbance: value as HabitatIndicators['litter_disturbance'] }))}>
                        {['low', 'medium', 'high'].map((value) => <option key={value}>{value}</option>)}
                      </Select>
                    </div>
                    <div className="flex flex-col gap-2">
                      <FieldLabel>Water</FieldLabel>
                      <Select value={habitat.water_presence} onChange={(value) => setHabitat((h) => ({ ...h, water_presence: value as HabitatIndicators['water_presence'] }))}>
                        {['none', 'puddle', 'ditch', 'stream', 'pond'].map((value) => <option key={value}>{value}</option>)}
                      </Select>
                    </div>
                    <div className="flex flex-col gap-2">
                      <FieldLabel>Light</FieldLabel>
                      <Select value={habitat.light_pollution} onChange={(value) => setHabitat((h) => ({ ...h, light_pollution: value as HabitatIndicators['light_pollution'] }))}>
                        {['none', 'low', 'moderate', 'high'].map((value) => <option key={value}>{value}</option>)}
                      </Select>
                    </div>
                    <div className="flex flex-col gap-2">
                      <FieldLabel>Invasive</FieldLabel>
                      <Select value={habitat.invasive_species_presence ? 'yes' : 'no'} onChange={(value) => setHabitat((h) => ({ ...h, invasive_species_presence: value === 'yes' }))}>
                        <option value="no">no</option>
                        <option value="yes">yes</option>
                      </Select>
                    </div>
                  </div>

                  {habitat.invasive_species_presence && (
                    <label className="flex items-center gap-3 rounded-lg border border-dashed border-[#D1D8CE] px-3 py-3 text-[12px] text-[#667066] cursor-pointer hover:border-[#2E6F40]">
                      <Camera size={14} strokeWidth={1.7} />
                      <span className="truncate">{invasivePhoto ? invasivePhoto.name : 'Required invasive species photo'}</span>
                      <input
                        type="file"
                        accept="image/*"
                        className="hidden"
                        onChange={(event) => setInvasivePhoto(event.target.files?.[0] ?? null)}
                      />
                    </label>
                  )}
                </div>

                <div className="bg-white border border-[#E4E7E1] rounded-lg p-4 flex flex-col gap-4">
                  <div className="flex items-center justify-between">
                    <h3 className="text-[14px] font-semibold text-[#1F2A1F]">Survey records</h3>
                    <button
                      type="button"
                      onClick={() => setRecords((prev) => [...prev, { taxon_group: 'bird', species_id: '', count: 1, notes: '' }])}
                      className="text-[11px] font-medium text-[#2E6F40] flex items-center gap-1"
                    >
                      <Plus size={12} />
                      Add
                    </button>
                  </div>

                  {records.map((record, index) => {
                    const options = species.filter((item) => item.taxon_group === record.taxon_group);
                    return (
                      <div key={index} className="rounded-lg border border-[#E4E7E1] p-3 flex flex-col gap-3">
                        <div className="grid grid-cols-2 gap-2">
                          <Select
                            value={record.taxon_group}
                            onChange={(value) => setRecords((prev) => prev.map((item, i) => i === index ? { ...item, taxon_group: value as TaxonGroup, species_id: '', saved: false } : item))}
                          >
                            {TAXON_GROUPS.map((group) => <option key={group.value} value={group.value}>{group.label}</option>)}
                          </Select>
                          <input
                            type="number"
                            min={0}
                            value={record.count}
                            onChange={(event) => setRecords((prev) => prev.map((item, i) => i === index ? { ...item, count: Number(event.target.value), saved: false } : item))}
                            className="rounded-lg border border-[#E4E7E1] px-3 py-2 text-[13px] outline-none focus:border-[#2E6F40]"
                          />
                        </div>
                        <Select
                          value={record.species_id}
                          onChange={(value) => setRecords((prev) => prev.map((item, i) => i === index ? { ...item, species_id: value, saved: false } : item))}
                        >
                          <option value="">Unknown species</option>
                          {options.map((item) => (
                            <option key={item.id} value={item.id}>{item.common_name} ({item.scientific_name})</option>
                          ))}
                        </Select>
                        <textarea
                          value={record.notes}
                          onChange={(event) => setRecords((prev) => prev.map((item, i) => i === index ? { ...item, notes: event.target.value, saved: false } : item))}
                          placeholder="Notes"
                          rows={2}
                          className="rounded-lg border border-[#E4E7E1] px-3 py-2 text-[13px] outline-none focus:border-[#2E6F40] resize-none"
                        />
                        <button
                          type="button"
                          onClick={() => handleSaveRecord(index)}
                          disabled={surveyBusy || record.saved}
                          className="h-9 rounded-lg border border-[#D1D8CE] text-[12px] font-semibold text-[#2E6F40] disabled:text-[#A8B4A8]"
                        >
                          {record.saved ? 'Saved' : 'Save record'}
                        </button>
                      </div>
                    );
                  })}
                </div>

                {surveyMessage && <StatusMessage kind={surveyMessage.kind}>{surveyMessage.text}</StatusMessage>}

                <button
                  type="button"
                  disabled={surveyBusy || elapsed < 15 * 60 || (habitat.invasive_species_presence && !invasivePhoto)}
                  onClick={handleSubmitSurvey}
                  className="h-11 rounded-lg bg-[#2E6F40] text-white text-[13px] font-semibold disabled:bg-[#D1D8CE]"
                >
                  {surveyBusy ? 'Submitting...' : 'Submit structured survey'}
                </button>
              </>
            )}

            {!activeSurvey && surveyMessage && <StatusMessage kind={surveyMessage.kind}>{surveyMessage.text}</StatusMessage>}
          </div>
        ) : (
          <div className="bg-white border border-[#E4E7E1] rounded-lg p-4 flex flex-col gap-4">
            <div className="flex items-center gap-2">
              <Leaf size={15} className="text-[#2E6F40]" strokeWidth={1.7} />
              <h3 className="text-[14px] font-semibold text-[#1F2A1F]">Suggestions queue</h3>
            </div>

            {!hasAuth && (
              <StatusMessage kind="warning">Sign in to submit suggestions.</StatusMessage>
            )}

            <div className="flex flex-col gap-2">
              <FieldLabel>Type</FieldLabel>
              <Select value={suggestionType} onChange={(value) => setSuggestionType(value as SuggestionType)}>
                {SUGGESTION_TYPES.map((item) => (
                  <option key={item.value} value={item.value}>{item.label}</option>
                ))}
              </Select>
            </div>

            <div className="flex flex-col gap-2">
              <FieldLabel>Suggestion</FieldLabel>
              <textarea
                value={suggestionText}
                onChange={(event) => setSuggestionText(event.target.value)}
                rows={5}
                className="rounded-lg border border-[#E4E7E1] px-3 py-2 text-[13px] outline-none focus:border-[#2E6F40] resize-none"
              />
            </div>

            {suggestionMessage && <StatusMessage kind={suggestionMessage.kind}>{suggestionMessage.text}</StatusMessage>}

            <button
              type="button"
              disabled={!hasAuth || suggestionBusy || !suggestionText.trim()}
              onClick={handleSuggestionSubmit}
              className="h-10 rounded-lg bg-[#2E6F40] text-white text-[13px] font-semibold disabled:bg-[#D1D8CE] disabled:text-white flex items-center justify-center gap-2"
            >
              <Send size={14} strokeWidth={1.8} />
              {suggestionBusy ? 'Submitting...' : 'Submit suggestion'}
            </button>
          </div>
        )}
      </div>
    </div>
  );
}
