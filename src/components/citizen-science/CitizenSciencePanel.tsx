'use client';

import { useState } from 'react';
import { cn } from '@/lib/utils';
import type { AppRole, SpeciesReferenceOption, SurveyPointFeature } from '@/lib/citizen-science';
import SurveyorSubmissionForm from './SurveyorSubmissionForm';
import ReviewQueue from './ReviewQueue';

type PanelView = 'submit' | 'review';

interface CitizenSciencePanelProps {
  role: AppRole | null;
  species: SpeciesReferenceOption[];
  surveyPoints: SurveyPointFeature[];
  selectedSurveyPoint: SurveyPointFeature | null;
  onSelectSurveyPoint: (point: SurveyPointFeature | null) => void;
  onRefreshMapData: () => void;
  cityId?: string;
}

function roleLabel(role: AppRole | null): string {
  if (!role) return 'Sign in to contribute';
  if (role === 'taxonomist') return 'Verifier access';
  if (role === 'admin') return 'Approver access';
  if (role === 'surveyor') return 'Surveyor access';
  return 'Contributor access';
}

export default function CitizenSciencePanel({
  role,
  species,
  surveyPoints,
  selectedSurveyPoint,
  onSelectSurveyPoint,
  onRefreshMapData,
  cityId,
}: CitizenSciencePanelProps) {
  const canReview = role === 'taxonomist' || role === 'admin';
  const [view, setView] = useState<PanelView>('submit');
  const activeView: PanelView = canReview ? view : 'submit';

  return (
    <div className="w-[440px] flex-shrink-0 bg-[#F7F8F5] border-l border-[#E4E7E1] flex flex-col overflow-hidden">
      <div className="bg-white border-b border-[#E4E7E1] px-5 py-4">
        <div className="flex items-center justify-between gap-3">
          <div>
            <h2 className="text-[16px] font-semibold text-[#1F2A1F]">Citizen science</h2>
            <p className="text-[12px] text-[#667066] mt-0.5">{roleLabel(role)}</p>
          </div>
          {canReview && (
            <div className="flex rounded-lg border border-[#E4E7E1] bg-[#F7F8F5] p-1">
              <button
                type="button"
                onClick={() => setView('submit')}
                className={cn(
                  'px-3 py-1.5 rounded-md text-[12px] font-medium',
                  activeView === 'submit' ? 'bg-white text-[#1F2A1F] shadow-sm' : 'text-[#667066]',
                )}
              >
                Submit
              </button>
              <button
                type="button"
                onClick={() => setView('review')}
                className={cn(
                  'px-3 py-1.5 rounded-md text-[12px] font-medium',
                  activeView === 'review' ? 'bg-white text-[#1F2A1F] shadow-sm' : 'text-[#667066]',
                )}
              >
                Review
              </button>
            </div>
          )}
        </div>
      </div>

      <div className="flex-1 overflow-y-auto p-5">
        {activeView === 'review' ? (
          <ReviewQueue role={role} onRefreshMapData={onRefreshMapData} />
        ) : (
          <SurveyorSubmissionForm
            role={role}
            species={species}
            surveyPoints={surveyPoints}
            selectedSurveyPoint={selectedSurveyPoint}
            onSelectSurveyPoint={onSelectSurveyPoint}
            onRefreshMapData={onRefreshMapData}
            cityId={cityId}
          />
        )}
      </div>
    </div>
  );
}
