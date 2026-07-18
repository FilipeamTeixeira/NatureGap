import Navbar from '@/components/layout/Navbar';
import { Calendar, MapPin, Users } from 'lucide-react';
import { fetchEvents } from '@/lib/data';
import { CITY } from '@/lib/config';

const TYPE_COLOR: Record<string, string> = {
  'Guided walk':     'text-[#2E6F40] bg-[#DDEAD8]',
  'Citizen science': 'text-[#3A6A8A] bg-[#E3EDF5]',
  'Restoration':     'text-[#9B6A1A] bg-[#FDF0DC]',
  'Event':           'text-[#667066] bg-[#F0F2EE]',
};

export default async function CommunityPage() {
  const events = await fetchEvents();

  return (
    <div className="h-full flex flex-col">
      <Navbar activePath="/community" />

      <div className="flex-1 overflow-y-auto bg-[#F7F8F5]">
        <div className="max-w-2xl mx-auto px-6 py-12">
          <h1 className="text-[32px] font-semibold text-[#1F2A1F] tracking-tight leading-tight mb-2">
            Community
          </h1>
          <p className="text-[14px] text-[#667066] mb-10 leading-relaxed">
            Local events and citizen science opportunities in {CITY.name}. Each event ties directly
            to high-priority map cells.
          </p>

          <div className="flex flex-col gap-3">
            {events.map(({ id, title, date, location, attendees, type }) => (
              <div
                key={id}
                className="bg-white rounded-2xl p-5 border border-[#E4E7E1]"
                style={{ boxShadow: '0 1px 2px rgba(0,0,0,0.03)' }}
              >
                <div className="flex items-start justify-between gap-3 mb-3">
                  <h2 className="text-[14px] font-semibold text-[#1F2A1F] leading-snug">{title}</h2>
                  <span
                    className={`text-[10px] font-semibold px-2.5 py-0.5 rounded-full flex-shrink-0 ${TYPE_COLOR[type] ?? 'text-[#667066] bg-[#F0F2EE]'}`}
                  >
                    {type}
                  </span>
                </div>

                <div className="flex flex-col gap-1">
                  <div className="flex items-center gap-2 text-[12px] text-[#667066]">
                    <Calendar size={11} className="text-[#A8B4A8]" />
                    {date}
                  </div>
                  <div className="flex items-center gap-2 text-[12px] text-[#667066]">
                    <MapPin size={11} className="text-[#A8B4A8]" />
                    {location}
                  </div>
                  <div className="flex items-center gap-2 text-[12px] text-[#667066]">
                    <Users size={11} className="text-[#A8B4A8]" />
                    {attendees} registered
                  </div>
                </div>
              </div>
            ))}
          </div>

          <p className="text-[11px] text-[#A8B4A8] mt-10 text-center">
            To list an event, open an issue on GitHub with the tag <code className="font-mono">community-event</code>.
          </p>
        </div>
      </div>
    </div>
  );
}
