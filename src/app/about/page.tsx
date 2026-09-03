import type { Metadata } from 'next';
import Navbar from '@/components/layout/Navbar';
import { LogoMark } from '@/components/layout/Logo';
import { SCORE_COLORS, SCORE_THRESHOLDS } from '@/lib/config';

export const metadata: Metadata = {
  title: 'About · Methods | NatureGap',
  description:
    'How NatureGap measures habitat, adjusts species records for search effort, calculates the Nature Gap score, and ranks restoration priorities, with its data sources and limitations.',
};

/** Renders a signed threshold with a true minus sign. */
const signed = (n: number) => n.toString().replace('-', '−');

const SCORE_BANDS = [
  {
    label: 'Much better than expected',
    range: `below ${signed(SCORE_THRESHOLDS.MUCH_BETTER)}`,
    color: SCORE_COLORS.MUCH_BETTER,
  },
  {
    label: 'Better than expected',
    range: `${signed(SCORE_THRESHOLDS.MUCH_BETTER)} to ${signed(SCORE_THRESHOLDS.BETTER)}`,
    color: SCORE_COLORS.BETTER,
  },
  {
    label: 'As expected',
    range: `${signed(SCORE_THRESHOLDS.BETTER)} to ${signed(SCORE_THRESHOLDS.AS_EXPECTED)}`,
    color: SCORE_COLORS.AS_EXPECTED,
  },
  {
    label: 'Worse than expected',
    range: `${signed(SCORE_THRESHOLDS.AS_EXPECTED)} to ${signed(SCORE_THRESHOLDS.WORSE)}`,
    color: SCORE_COLORS.WORSE,
  },
  {
    label: 'Much worse than expected',
    range: `${signed(SCORE_THRESHOLDS.WORSE)} and above`,
    color: SCORE_COLORS.MUCH_WORSE,
  },
];

const STEPS = [
  {
    title: 'Divide the city into cells',
    body: 'The city is split into hexagons 20 metres across. Every measurement described below attaches to one of these cells, so any two figures on the site refer to exactly the same piece of ground.',
  },
  {
    title: 'Measure the habitat',
    body: 'Satellite imagery and open map data describe how green each cell is, how hot it gets, and how heavily people use it. Those three readings combine into a single habitat quality score.',
  },
  {
    title: 'Adjust for how well an area has been searched',
    body: 'Wildlife records cluster along footpaths, because that is where people walk. Each cell’s species count is therefore adjusted for how easily it can be searched. Cells that almost nobody can reach are set aside, rather than recorded as having no wildlife.',
  },
  {
    title: 'Compare what was found with what was expected',
    body: 'A statistical model learns how species richness relates to habitat, connectivity and access across the whole city, then predicts what each cell should hold. Expected minus observed is the gap.',
  },
  {
    title: 'Rank the restoration opportunities',
    body: 'A cell rises to the top of the list when it falls short of its prediction and also sits on an important route between patches of habitat.',
  },
];

const DATA_SOURCES = [
  {
    label: 'Satellite',
    body: 'Sentinel-2 measures vegetation. Landsat measures surface temperature, averaged over three seasonal windows so that a single hot day cannot dominate. ESA WorldCover classifies ground as built or vegetated.',
  },
  {
    label: 'Aerial photography',
    body: 'Infrared aerial photography reads vegetation far more finely than any satellite can. Portugal and the Netherlands publish it openly, so Porto and Amsterdam use it. Nothing equivalent exists for Yokohama, which falls back on the coarser satellite classes and produces blockier corridors as a result.',
  },
  {
    label: 'Open mapping',
    body: 'OpenStreetMap supplies footpaths, parks, amenities, roads and street lighting. Footpaths serve two purposes. They indicate how much human activity a cell sees, and they estimate how thoroughly it has been searched for wildlife.',
  },
  {
    label: 'Species records',
    body: 'iNaturalist and GBIF, together with surveys submitted through this site. A structured survey follows a set protocol, runs for a fixed time and records habitat conditions, so it counts for more than a casual sighting. Casual sightings still appear on the map, but they do not change the modelled scores. Rejected and flagged records are left out.',
  },
];

const METRICS = [
  {
    title: 'Habitat quality',
    body: 'How suitable a cell is as habitat, scored from 0 to 1. Vegetation contributes half of it. Coolness contributes roughly 29 per cent, measured as surface temperature and inverted, so shaded and planted ground scores above bare asphalt. Freedom from human activity contributes roughly 21 per cent, judged from nearby footpaths and amenities. Noise, lighting, water, tree height and sealed surface are all measured and shown on the map, but they are not part of this score.',
  },
  {
    title: 'Observed richness',
    body: 'How many different species have been recorded in a cell, adjusted for how thoroughly it has been searched. Search effort is estimated from the length of footpath within 40 metres of the cell. The radius reaches beyond the cell itself because a garden just off a path is still easy to observe from it. A cell with less than 50 metres of nearby path is marked unsampled and carries no richness value at all.',
  },
  {
    title: 'Expected richness',
    body: 'What that adjusted richness should be, given the cell’s habitat, its position in the corridor network, and how reachable it is. The relationship is worked out separately for each city, using only cells that have actually been searched. Species counts at this scale are extremely uneven, and the model is chosen to handle that. Because every city gets its own fit, expected richness is a local benchmark and carries no meaning across city boundaries.',
  },
  {
    title: 'Ecological residual',
    body: 'Expected richness minus observed richness. A positive figure means fewer species were found than habitat and connectivity predict, which points to a shortfall. A negative figure means more were found than predicted, which can mark a refuge. This is what the model could not explain, not a direct measure of ecological loss.',
  },
  {
    title: 'Nature Gap score',
    body: 'The headline number. The ecological residual supplies half of it. Weak habitat quality supplies 30 per cent, and weak connectivity the remaining 20 per cent. Each part is measured against the typical cell in the same city, so zero means ordinary for that city rather than adequate in any absolute sense. The point of comparison is recalculated on every run, which makes a score meaningful within one city and one analysis, and nowhere else.',
  },
  {
    title: 'Corridor importance',
    body: 'How often a cell lies on an efficient route between patches of habitat. Neighbouring cells form a network in which movement grows more costly as vegetation gives way to concrete, and stops altogether where the ground is entirely built. Only routes short enough for an animal to plausibly travel are counted. A cell scoring zero carries no route at all. That places it outside the network, rather than making it a weak part of one.',
  },
  {
    title: 'Restoration priority',
    body: 'Where work would achieve the most. A cell scores only if it is both performing worse than the typical cell in its city and carrying real connectivity value. Excellent habitat with no shortfall does not qualify, and neither does a large shortfall in an isolated pocket. For the highest-ranked cells, the model also estimates how much connectivity restoring them would add.',
  },
];

const RELIABILITY = [
  {
    verdict: 'Robust',
    title: 'The habitat weights',
    body: 'The split between greenness, coolness and disturbance is the most obviously arbitrary part of the model. Pushing those weights to their extremes still leaves 80 per cent of Porto’s top twenty sites in place, and 94 per cent of its top thousand. Cities with fewer records hold up less well, and Yokohama has the fewest.',
  },
  {
    verdict: 'Robust',
    title: 'The search threshold',
    body: 'The 50-metre path minimum decides which cells are analysed at all. Moving it changes the analysed area by almost a factor of four, so it matters for any claim about how much of a city has been covered. It has little effect on which sites reach the top of the restoration list.',
  },
  {
    verdict: 'Not robust',
    title: 'The cost of crossing built ground',
    body: 'One constant genuinely changes the answer. Making built surfaces harder to cross reorders the restoration list. At the most extreme value tested, only one of Amsterdam’s top twenty sites survives, and fewer than half of Porto’s. Until this figure is calibrated against real dispersal data, the ranking is a starting point for fieldwork rather than a settled result.',
  },
];

const LIMITATIONS = [
  'Most records come from volunteers, so they cluster near homes and popular parks and favour species that are easy to spot. Footpath length estimates where people searched. It says nothing about their skill, the time of year, or land the public cannot enter.',
  'Satellite greenness cannot separate native planting from ornamental or invasive growth. Surface temperature still depends on which days the satellite passed overhead, even after seasonal averaging.',
  'OpenStreetMap coverage varies between cities. Both the disturbance reading and the search-effort adjustment inherit whatever is missing locally.',
  'Most 20-metre cells contain no species records at all. The model explains roughly a fifth of the variation in Porto and less in the sparser cities. The signal is real but weak, and whether it supports decisions cell by cell, rather than neighbourhood by neighbourhood, is still an open question.',
  'Expected richness is fitted and tested on the same data, so the residual is not independent of the model that produced it.',
  'Connectivity uses a generic vegetation-against-concrete model. It does not represent the needs of any particular species, and it does not yet identify individual barriers such as a specific road or railway. The estimated gain from restoring a cell is a local approximation, not a full simulation.',
  'Fragmentation, patch isolation and similar landscape measures are not yet calculated, and nothing on this site uses them.',
];

export default function AboutPage() {
  return (
    <div className="h-full flex flex-col">
      <Navbar activePath="/about" />

      <div className="flex-1 overflow-y-auto bg-[#F7F8F5]">
        <div className="max-w-2xl mx-auto px-6 py-12">
          <div className="flex items-center gap-2.5 mb-6">
            <LogoMark size={34} className="flex-shrink-0" />
            <h1 className="text-[32px] font-semibold text-[#1F2A1F] tracking-tight leading-tight">
              About NatureGap
            </h1>
          </div>

          <p className="text-[15px] text-[#3F4A3F] leading-relaxed mb-4">
            Some parts of a city hold less wildlife than their habitat suggests they should.
            NatureGap measures that shortfall. It estimates the biodiversity each patch of
            ground could support, compares it against the species actually recorded there,
            and maps the difference.
          </p>
          <p className="text-[14px] text-[#667066] leading-relaxed mb-12">
            The map covers <strong className="text-[#1F2A1F] font-semibold">Porto</strong>,{' '}
             <strong className="text-[#1F2A1F] font-semibold">Ghent</strong>, {' '}
            <strong className="text-[#1F2A1F] font-semibold">Amsterdam</strong> and{' '}
            <strong className="text-[#1F2A1F] font-semibold">Yokohama</strong>. Each city is
            analysed separately, using the same method. Three cities on two continents keep
            the approach from being tuned to any one country’s data.
          </p>

          <h2 className="text-[18px] font-semibold text-[#1F2A1F] mb-5">How it works</h2>
          <ol className="flex flex-col gap-5 mb-12">
            {STEPS.map(({ title, body }, index) => (
              <li key={title} className="flex gap-4">
                <span className="w-6 h-6 rounded-full bg-[#DDEAD8] text-[#2E6F40] text-[11px] font-semibold flex items-center justify-center flex-shrink-0 mt-0.5">
                  {index + 1}
                </span>
                <div>
                  <h3 className="text-[14px] font-semibold text-[#1F2A1F] mb-1">{title}</h3>
                  <p className="text-[13px] text-[#667066] leading-relaxed">{body}</p>
                </div>
              </li>
            ))}
          </ol>

          <h2 className="text-[18px] font-semibold text-[#1F2A1F] mb-2">
            Where the data comes from
          </h2>
          <p className="text-[14px] text-[#667066] leading-relaxed mb-5">
            Every input is open data. Nothing on the map depends on a commercial or
            restricted source.
          </p>
          <dl className="border-t border-[#E4E7E1] mb-6">
            {DATA_SOURCES.map(({ label, body }) => (
              <div
                key={label}
                className="border-b border-[#E4E7E1] py-4 sm:grid sm:grid-cols-[132px_minmax(0,1fr)] sm:gap-6"
              >
                <dt className="text-[13px] font-semibold text-[#1F2A1F] mb-1 sm:mb-0">
                  {label}
                </dt>
                <dd className="text-[13px] text-[#667066] leading-relaxed">{body}</dd>
              </div>
            ))}
          </dl>
          <p className="text-[13px] text-[#667066] leading-relaxed mb-12">
            Records submitted here follow a few rules. The first record of a species needs a
            photograph. GPS accuracy is stored with every submission and taken into account
            when weighting it. Sightings repeated within thirty minutes are flagged as
            possible duplicates. New records show on the map immediately, but scores only
            change after the next full analysis run.
          </p>

          <h2 className="text-[18px] font-semibold text-[#1F2A1F] mb-2">The metrics</h2>
          <p className="text-[14px] text-[#667066] leading-relaxed mb-5">
            Each of these is calculated for every cell in the grid, and shown in the detail
            panel when you click a cell on the map.
          </p>
          <div className="flex flex-col gap-3 mb-8">
            {METRICS.map(({ title, body }) => (
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

          <div
            className="bg-white rounded-2xl p-5 border border-[#E4E7E1] mb-12"
            style={{ boxShadow: '0 1px 2px rgba(0,0,0,0.03)' }}
          >
            <h3 className="text-[13px] font-semibold text-[#1F2A1F] mb-1">
              Reading the Nature Gap score
            </h3>
            <p className="text-[12px] text-[#667066] leading-relaxed mb-4">
              Scores run from −100 to +100. A higher score means the cell falls further
              below what its habitat predicts.
            </p>
            <ul className="flex flex-col gap-2">
              {SCORE_BANDS.map(({ label, range, color }) => (
                <li key={label} className="flex items-center gap-3">
                  <span
                    className="w-3 h-3 rounded-full flex-shrink-0"
                    style={{ backgroundColor: color }}
                  />
                  <span className="text-[12px] text-[#1F2A1F] flex-1">{label}</span>
                  <span className="text-[11px] text-[#A8B4A8] tabular-nums">{range}</span>
                </li>
              ))}
            </ul>
          </div>

          <h2 className="text-[18px] font-semibold text-[#1F2A1F] mb-3">
            Parks and the corridor network
          </h2>
          <p className="text-[14px] text-[#667066] leading-relaxed mb-3">
            Parks are scored as whole units as well as cell by cell, because size matters in
            its own right. A large green space supports more species than a small one of the
            same quality. A park’s expected richness therefore comes from its total area,
            its average habitat and connectivity, and the search effort pooled across all
            its cells. Its observed richness counts the distinct species found anywhere
            inside it against that same pooled effort. Park scores and cell scores measure
            the same kind of thing on different scales, and should not be compared with each
            other.
          </p>
          <p className="text-[14px] text-[#667066] leading-relaxed mb-12">
            Zoomed out, the map draws a simplified network in place of individual cells.
            Blocks of core habitat appear as nodes, joined by the cheapest routes between
            them. Weak stretches along a route are marked as bottlenecks rather than hidden.
            The network is drawn from the connectivity analysis and does not feed back into
            any score.
          </p>

          <h2 className="text-[18px] font-semibold text-[#1F2A1F] mb-2">
            How much to trust the numbers
          </h2>
          <p className="text-[14px] text-[#667066] leading-relaxed mb-5">
            Several constants in the model were set by judgement rather than measured. Each
            was tested by running the whole analysis again across a range of plausible
            values, then checking how far the restoration ranking moved.
          </p>
          <div className="flex flex-col gap-3 mb-12">
            {RELIABILITY.map(({ verdict, title, body }) => (
              <div
                key={title}
                className="bg-white rounded-2xl p-5 border border-[#E4E7E1]"
                style={{ boxShadow: '0 1px 2px rgba(0,0,0,0.03)' }}
              >
                <div className="flex items-center gap-2.5 mb-1.5">
                  <span
                    className={
                      verdict === 'Robust'
                        ? 'text-[10px] font-semibold px-2.5 py-0.5 rounded-full text-[#2E6F40] bg-[#DDEAD8]'
                        : 'text-[10px] font-semibold px-2.5 py-0.5 rounded-full text-[#A8432F] bg-[#F8DED8]'
                    }
                  >
                    {verdict}
                  </span>
                  <h3 className="text-[13px] font-semibold text-[#1F2A1F]">{title}</h3>
                </div>
                <p className="text-[12px] text-[#667066] leading-relaxed">{body}</p>
              </div>
            ))}
          </div>

          <h2 className="text-[18px] font-semibold text-[#1F2A1F] mb-2">Limitations</h2>
          <p className="text-[14px] text-[#667066] leading-relaxed mb-4">
            These weaknesses are worth knowing before acting on anything the map shows.
          </p>
          <ul className="list-disc pl-5 flex flex-col gap-3 mb-12 marker:text-[#B8C9AE]">
            {LIMITATIONS.map((item) => (
              <li key={item} className="text-[13px] text-[#667066] leading-relaxed pl-1">
                {item}
              </li>
            ))}
          </ul>

          <h2 className="text-[18px] font-semibold text-[#1F2A1F] mb-3">
            Scope and licensing
          </h2>
          <p className="text-[14px] text-[#667066] leading-relaxed mb-3">
            NatureGap shows where urban habitat is under-delivering by the standards of its
            own city, and where restoration would close that gap most efficiently. It is not
            a species inventory, an offset calculator, or a way to rank one city against
            another.
          </p>
          <p className="text-[14px] text-[#667066] leading-relaxed">
            The analysis, its documentation and this application are all public. Code is MIT
            licensed, and documentation and data are CC BY-SA 4.0. Any city with comparable
            open data can be added.
          </p>
        </div>
      </div>
    </div>
  );
}
