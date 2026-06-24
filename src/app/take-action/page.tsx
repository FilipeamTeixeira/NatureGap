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
      'Yokohama\'s urban forestry programme runs quarterly planting events. Each tree planted in a fragmentation gap measurably increases corridor connectivity.',
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

export default function TakeActionPage() {
  return (
    <div className="h-full flex flex-col">
      <Navbar activePath="/take-action" />

      <div className="flex-1 overflow-y-auto bg-[#f7f8f6]">
        <div className="max-w-2xl mx-auto px-6 py-12">
          <h1 className="text-2xl font-semibold text-neutral-900 mb-2">Take action</h1>
          <p className="text-sm text-neutral-500 mb-10 leading-relaxed">
            Every action below is ranked by ecological impact. Start with what fits your time, and use the map
            to find where your effort will matter most.
          </p>

          <div className="flex flex-col gap-4">
            {ACTIONS.map(({ icon: Icon, title, description, impact, time }) => (
              <div key={title} className="bg-white rounded-2xl p-6 border border-[#e4e7e3]">
                <div className="flex items-start gap-4">
                  <div className="w-9 h-9 bg-[#f0f4ee] rounded-xl flex items-center justify-center flex-shrink-0">
                    <Icon size={16} className="text-[#3d6b2f]" />
                  </div>
                  <div className="flex-1">
                    <div className="flex items-center gap-3 mb-1">
                      <h2 className="text-sm font-semibold text-neutral-900">{title}</h2>
                      <span className="text-[10px] font-semibold text-[#3d6b2f] bg-[#f0f4ee] px-2 py-0.5 rounded-full">
                        {impact}
                      </span>
                    </div>
                    <p className="text-xs text-neutral-500 leading-relaxed mb-2">{description}</p>
                    <span className="text-[10px] text-neutral-400">{time}</span>
                  </div>
                </div>
              </div>
            ))}
          </div>

          <p className="text-xs text-neutral-400 mt-10 text-center">
            More actions will appear here once the data pipeline is running for your ward.
          </p>
        </div>
      </div>
    </div>
  );
}
