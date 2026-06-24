import Navbar from '@/components/layout/Navbar';
import { TreePine, Flower2, Leaf, Zap } from 'lucide-react';

const ACTIONS = [
  {
    icon: Flower2,
    title: 'Plant for pollinators',
    description:
      'Native flowering plants in your garden, balcony, or street verge directly increase local insect diversity. Focus on species that bloom across the full season.',
    impact: 'High impact',
    time: '1–2 hours',
  },
  {
    icon: TreePine,
    title: 'Join a tree-planting day',
    description:
      "Yokohama's urban forestry programme runs quarterly planting events. Each tree planted in a fragmentation gap measurably increases corridor connectivity.",
    impact: 'High impact',
    time: 'Half day',
  },
  {
    icon: Leaf,
    title: 'Record a sighting on iNaturalist',
    description:
      'Every observation strengthens the biodiversity baseline used to calculate the nature impact score. Research-grade records count directly in the pipeline.',
    impact: 'Medium impact',
    time: '5 minutes',
  },
  {
    icon: Zap,
    title: 'Advocate for a corridor',
    description:
      'Use the map to identify fragmentation bottlenecks in your ward, then raise the issue with your local council. The intervention ranking gives you the data to make the case.',
    impact: 'High impact (long-term)',
    time: 'Ongoing',
  },
];

const IMPACT_COLOR: Record<string, string> = {
  'High impact': 'text-[#2E6F40] bg-[#DDEAD8]',
  'High impact (long-term)': 'text-[#2E6F40] bg-[#DDEAD8]',
  'Medium impact': 'text-[#9B6A1A] bg-[#FDF0DC]',
};

export default function TakeActionPage() {
  return (
    <div className="h-full flex flex-col">
      <Navbar activePath="/take-action" />

      <div className="flex-1 overflow-y-auto bg-[#F7F8F5]">
        <div className="max-w-2xl mx-auto px-6 py-12">
          <h1 className="text-[32px] font-semibold text-[#1F2A1F] tracking-tight leading-tight mb-2">
            Take action
          </h1>
          <p className="text-[14px] text-[#667066] mb-10 leading-relaxed">
            Every action below is ranked by ecological impact. Start with what fits your time, and
            use the map to find where your effort will matter most.
          </p>

          <div className="flex flex-col gap-3">
            {ACTIONS.map(({ icon: Icon, title, description, impact, time }) => (
              <div
                key={title}
                className="bg-white rounded-2xl p-6 border border-[#E4E7E1]"
                style={{ boxShadow: '0 1px 2px rgba(0,0,0,0.03)' }}
              >
                <div className="flex items-start gap-4">
                  <div className="w-9 h-9 bg-[#F7F8F5] rounded-xl flex items-center justify-center flex-shrink-0">
                    <Icon size={16} className="text-[#2E6F40]" strokeWidth={1.5} />
                  </div>
                  <div className="flex-1">
                    <div className="flex items-center gap-3 mb-1.5">
                      <h2 className="text-[14px] font-semibold text-[#1F2A1F]">{title}</h2>
                      <span
                        className={`text-[10px] font-semibold px-2.5 py-0.5 rounded-full ${IMPACT_COLOR[impact] ?? 'text-[#667066] bg-[#F0F2EE]'}`}
                      >
                        {impact}
                      </span>
                    </div>
                    <p className="text-[12px] text-[#667066] leading-relaxed mb-2">{description}</p>
                    <span className="text-[11px] text-[#A8B4A8]">{time}</span>
                  </div>
                </div>
              </div>
            ))}
          </div>

          <p className="text-[11px] text-[#A8B4A8] mt-10 text-center">
            More actions will appear here once the data pipeline is running for your ward.
          </p>
        </div>
      </div>
    </div>
  );
}
