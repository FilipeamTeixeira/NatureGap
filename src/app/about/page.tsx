import Navbar from '@/components/layout/Navbar';
import { Leaf, FolderGit, BookOpen, Database } from 'lucide-react';

const PRINCIPLES = [
  {
    title: 'Methodologically honest',
    body: 'Every index is documented with its inputs, assumptions, and known limitations. The nature impact score is a relative ranking, not an absolute prediction.',
  },
  {
    title: 'Observation-effort corrected',
    body: 'Citizen-science records (iNaturalist, GBIF) are normalised by the length of accessible paths per cell, so the map reflects real ecological pressure — not where people happen to walk.',
  },
  {
    title: 'Graph-theoretic interventions',
    body: 'Restoration recommendations are ranked by betweenness centrality in the habitat connectivity graph. "Restore this corridor" means it measurably reduces fragmentation more than any other candidate cell.',
  },
  {
    title: 'Fully open source',
    body: 'The R data pipeline, methodology documentation, and this application are all public. Anyone can re-run the analysis for any city with open data coverage.',
  },
];

export default function AboutPage() {
  return (
    <div className="h-full flex flex-col">
      <Navbar activePath="/about" />

      <div className="flex-1 overflow-y-auto bg-[#F7F8F5]">
        <div className="max-w-2xl mx-auto px-6 py-12">
          <div className="flex items-center gap-2.5 mb-6">
            <div className="w-8 h-8 bg-[#2E6F40] rounded-lg flex items-center justify-center flex-shrink-0">
              <Leaf size={14} strokeWidth={2} className="text-white" />
            </div>
            <h1 className="text-[24px] font-semibold text-[#1F2A1F] tracking-tight">
              About NatureGap
            </h1>
          </div>

          <p className="text-[14px] text-[#667066] leading-relaxed mb-4">
            NatureGap is an open-source tool that compares the biodiversity your neighbourhood{' '}
            <em>should</em> support — based on habitat quality — with what is actually recorded
            there. The gap is the nature impact score.
          </p>
          <p className="text-[14px] text-[#667066] leading-relaxed mb-10">
            The first city is <strong className="text-[#1F2A1F] font-semibold">Yokohama, Japan</strong>. A
            second European city is planned to demonstrate transferability. The methodology is
            designed to be publishable as a standalone methods paper.
          </p>

          <p className="text-[10px] font-semibold text-[#667066] uppercase tracking-widest mb-4">
            Design principles
          </p>
          <div className="flex flex-col gap-3 mb-10">
            {PRINCIPLES.map(({ title, body }) => (
              <div
                key={title}
                className="bg-white rounded-2xl p-5 border border-[#E4E7E1]"
                style={{ boxShadow: '0 1px 2px rgba(0,0,0,0.03)' }}
              >
                <h3 className="text-[13px] font-semibold text-[#1F2A1F] mb-1.5">{title}</h3>
                <p className="text-[12px] text-[#667066] leading-relaxed">{body}</p>
              </div>
            ))}
          </div>

          <p className="text-[10px] font-semibold text-[#667066] uppercase tracking-widest mb-4">
            Resources
          </p>
          <div className="flex flex-col gap-2.5">
            {[
              { icon: FolderGit, label: 'Source code',   sub: 'Available in this project repository' },
              { icon: BookOpen,  label: 'Methodology',   sub: 'See docs/methodology.md' },
              { icon: Database,  label: 'Data pipeline', sub: 'R scripts in pipeline/' },
            ].map(({ icon: Icon, label, sub }) => (
              <div
                key={label}
                className="flex items-center gap-4 bg-white rounded-2xl p-4 border border-[#E4E7E1]"
                style={{ boxShadow: '0 1px 2px rgba(0,0,0,0.03)' }}
              >
                <div className="w-8 h-8 bg-[#F7F8F5] rounded-lg flex items-center justify-center flex-shrink-0">
                  <Icon size={14} className="text-[#2E6F40]" strokeWidth={1.5} />
                </div>
                <div>
                  <div className="text-[13px] font-medium text-[#1F2A1F]">{label}</div>
                  <div className="text-[11px] text-[#667066]">{sub}</div>
                </div>
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}
