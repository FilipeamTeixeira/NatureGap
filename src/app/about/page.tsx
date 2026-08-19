import Navbar from '@/components/layout/Navbar';
import { Leaf, FolderGit, BookOpen, Database, Network } from 'lucide-react';

const PRINCIPLES = [
  {
    title: 'Methodologically honest',
    body: 'Every index is documented with its inputs, assumptions, and known limitations. The Nature Gap score is a within-city relative ranking, not an absolute species prediction, and its weights are expert-assigned rather than calibrated.',
  },
  {
    title: 'Observation-effort corrected',
    body: 'Citizen-science records (iNaturalist, GBIF, and approved surveys submitted here) are divided by the pedestrian path length within 40 m of each cell, so the map reflects real ecological pressure — not where people happen to walk. A cell with under 50 m of accessible path is marked unsampled and left out of the analysis rather than scored as empty.',
  },
  {
    title: 'Graph-theoretic interventions',
    body: 'Restoration recommendations are ranked by dispersal-limited betweenness centrality on the habitat connectivity graph, where the cost of crossing each 20 m cell rises as vegetation gives way to built surface. "Restore this corridor" means it sits on more of the low-resistance routes between habitat patches than any other candidate cell — improving connectivity most efficiently.',
  },
  {
    title: 'Fully open source',
    body: 'The R data pipeline, methodology documentation, and this application are all public — code under MIT, documentation and data under CC BY-SA 4.0. Anyone can re-run the analysis for any city with open data coverage: adding one takes a single small config file.',
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
            <h1 className="text-[32px] font-semibold text-[#1F2A1F] tracking-tight leading-tight">
              About NatureGap
            </h1>
          </div>

          <p className="text-[14px] text-[#667066] leading-relaxed mb-4">
            NatureGap is an open-source tool that compares the biodiversity your neighbourhood{' '}
            <em>should</em> support — based on habitat quality — with what is actually recorded
            there. The difference is the Nature Gap score: a positive score means fewer species
            are recorded than the habitat predicts, a negative score means more.
          </p>
          <p className="text-[14px] text-[#667066] leading-relaxed mb-10">
            Three areas are analysed today —{' '}
            <strong className="text-[#1F2A1F] font-semibold">Porto</strong>,{' '}
            <strong className="text-[#1F2A1F] font-semibold">Amsterdam</strong>, and{' '}
            <strong className="text-[#1F2A1F] font-semibold">Honmoku, Yokohama</strong> — chosen
            across two continents to show that the same method transfers. The methodology is
            designed to be publishable as a standalone methods paper.
          </p>

          <h2 className="text-[18px] font-semibold text-[#1F2A1F] mb-4">
            Design principles
          </h2>
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

          <h2 className="text-[18px] font-semibold text-[#1F2A1F] mb-4">
            Resources
          </h2>
          <div className="flex flex-col gap-2.5">
            {[
              { icon: FolderGit, label: 'Source code',   sub: 'MIT licensed, in this project repository' },
              { icon: BookOpen,  label: 'Methodology',   sub: 'docs/methodology.md — formulas, assumptions, limitations' },
              { icon: Database,  label: 'Data pipeline', sub: 'R scripts in pipeline/, one stage per folder' },
              { icon: Network,   label: 'Ecological network', sub: 'Habitat cores and least-cost corridors, drawn on the map' },
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
