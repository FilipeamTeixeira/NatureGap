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

      <div className="flex-1 overflow-y-auto bg-[#f7f8f6]">
        <div className="max-w-2xl mx-auto px-6 py-12">
          <div className="flex items-center gap-2.5 mb-6">
            <Leaf size={20} className="text-[#3d6b2f]" strokeWidth={2} />
            <h1 className="text-2xl font-semibold text-neutral-900">About NatureGap</h1>
          </div>

          <p className="text-sm text-neutral-600 leading-relaxed mb-4">
            NatureGap is an open-source tool that compares the biodiversity your neighbourhood
            <em> should</em> support — based on habitat quality — with what is actually recorded
            there. The gap is the nature impact score.
          </p>
          <p className="text-sm text-neutral-600 leading-relaxed mb-10">
            The first city is <strong>Yokohama, Japan</strong>. A second European city is planned
            to demonstrate transferability. The methodology is designed to be publishable as a
            standalone methods paper.
          </p>

          <h2 className="text-xs font-semibold text-neutral-400 uppercase tracking-widest mb-4">
            Design principles
          </h2>
          <div className="flex flex-col gap-4 mb-10">
            {PRINCIPLES.map(({ title, body }) => (
              <div key={title} className="bg-white rounded-2xl p-5 border border-[#e4e7e3]">
                <h3 className="text-sm font-semibold text-neutral-900 mb-1">{title}</h3>
                <p className="text-xs text-neutral-500 leading-relaxed">{body}</p>
              </div>
            ))}
          </div>

          <h2 className="text-xs font-semibold text-neutral-400 uppercase tracking-widest mb-4">
            Resources
          </h2>
          <div className="flex flex-col gap-3">
            {[
              { icon: FolderGit, label: 'Source code', sub: 'Available in this project repository' },
              { icon: BookOpen, label: 'Methodology', sub: 'See docs/methodology.md' },
              { icon: Database, label: 'Data pipeline', sub: 'R scripts in pipeline/' },
            ].map(({ icon: Icon, label, sub }) => (
              <div
                key={label}
                className="flex items-center gap-4 bg-white rounded-2xl p-4 border border-[#e4e7e3]"
              >
                <div className="w-8 h-8 bg-[#f0f4ee] rounded-lg flex items-center justify-center flex-shrink-0">
                  <Icon size={14} className="text-[#3d6b2f]" />
                </div>
                <div>
                  <div className="text-sm font-medium text-neutral-800">{label}</div>
                  <div className="text-[11px] text-neutral-400">{sub}</div>
                </div>
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}
