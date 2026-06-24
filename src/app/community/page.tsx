import Navbar from '@/components/layout/Navbar';
import { Users, MapPin, CalendarDays } from 'lucide-react';

const EVENTS = [
  {
    title: 'Honmoku Bioblitz',
    location: 'Sancho Park, Naka Ward',
    date: 'Sat 12 Jul 2026 · 08:00',
    description: 'Morning survey of Sancho and Shinhonmoku parks. All levels welcome. Bring the iNaturalist app.',
    spots: 18,
  },
  {
    title: 'Yokohama Nature Walk',
    location: 'Negishi Forest Park, Isogo',
    date: 'Sun 20 Jul 2026 · 09:30',
    description: 'Guided walk focusing on birds and summer insects. Led by local naturalist group.',
    spots: 12,
  },
  {
    title: 'Kishine Park Planting Day',
    location: 'Kishine Park, Kohoku Ward',
    date: 'Sat 2 Aug 2026 · 09:00',
    description: 'Native understorey planting to close the Kohoku corridor gap. Tools and gloves provided.',
    spots: 24,
  },
];

export default function CommunityPage() {
  return (
    <div className="h-full flex flex-col">
      <Navbar activePath="/community" />

      <div className="flex-1 overflow-y-auto bg-[#f7f8f6]">
        <div className="max-w-2xl mx-auto px-6 py-12">
          <h1 className="text-2xl font-semibold text-neutral-900 mb-2">Community</h1>
          <p className="text-sm text-neutral-500 mb-10 leading-relaxed">
            Local groups, upcoming events, and projects. The map is only as good as the observations
            people contribute — here is how to get involved.
          </p>

          <h2 className="text-xs font-semibold text-neutral-400 uppercase tracking-widest mb-4">
            Upcoming events
          </h2>

          <div className="flex flex-col gap-4 mb-12">
            {EVENTS.map(({ title, location, date, description, spots }) => (
              <div key={title} className="bg-white rounded-2xl p-6 border border-[#e4e7e3]">
                <div className="flex items-start justify-between gap-4">
                  <div>
                    <h3 className="text-sm font-semibold text-neutral-900 mb-2">{title}</h3>
                    <div className="flex items-center gap-1.5 text-[11px] text-neutral-400 mb-1">
                      <MapPin size={10} />
                      {location}
                    </div>
                    <div className="flex items-center gap-1.5 text-[11px] text-neutral-400 mb-3">
                      <CalendarDays size={10} />
                      {date}
                    </div>
                    <p className="text-xs text-neutral-500 leading-relaxed">{description}</p>
                  </div>
                  <div className="flex flex-col items-end gap-2 flex-shrink-0">
                    <div className="flex items-center gap-1.5 text-[11px] text-neutral-400">
                      <Users size={10} />
                      {spots} spots
                    </div>
                    <span className="text-[10px] font-medium text-neutral-400 bg-[#f7f8f6] px-2.5 py-1 rounded-full">
                      Sign-ups opening soon
                    </span>
                  </div>
                </div>
              </div>
            ))}
          </div>

          <div className="bg-white rounded-2xl p-6 border border-[#e4e7e3]">
            <h2 className="text-sm font-semibold text-neutral-900 mb-1">Suggest an event</h2>
            <p className="text-xs text-neutral-500 leading-relaxed">
              Running a survey, planting session, or community clean-up? Add it here so others
              can find and join.
            </p>
            <p className="mt-3 text-[11px] text-neutral-400">
              Event submission will be enabled after community accounts are connected.
            </p>
          </div>
        </div>
      </div>
    </div>
  );
}
