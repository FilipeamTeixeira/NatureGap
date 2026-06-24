const MONTHS = ['Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun'];
const MONTH_INDICES = [0, 3, 6, 9, 11];

interface TrendChartProps {
  data: number[];
}

export default function TrendChart({ data }: TrendChartProps) {
  const W = 280;
  const H = 72;
  const padX = 8;
  const padY = 8;
  const innerW = W - padX * 2;
  const innerH = H - padY * 2;

  const min = Math.min(...data);
  const max = Math.max(...data);
  const range = max - min || 1;

  const pts = data.map((v, i) => ({
    x: padX + (i / (data.length - 1)) * innerW,
    y: padY + (1 - (v - min) / range) * innerH,
  }));

  const polyline = pts.map((p) => `${p.x},${p.y}`).join(' ');

  const areaPath = [
    `M ${pts[0].x} ${H - padY}`,
    ...pts.map((p) => `L ${p.x} ${p.y}`),
    `L ${pts[pts.length - 1].x} ${H - padY}`,
    'Z',
  ].join(' ');

  const zeroFrac = (0 - min) / range;
  const zeroY = padY + (1 - zeroFrac) * innerH;
  const showZero = min < 0 && max > 0;

  const isPositive = data[data.length - 1] >= data[0];
  const lineColor = isPositive ? '#2E6F40' : '#E8A44C';
  const fillId = `grad-${isPositive ? 'pos' : 'neg'}`;

  return (
    <svg viewBox={`0 0 ${W} ${H + 18}`} className="w-full">
      <defs>
        <linearGradient id={fillId} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor={lineColor} stopOpacity="0.12" />
          <stop offset="100%" stopColor={lineColor} stopOpacity="0" />
        </linearGradient>
      </defs>

      {showZero && (
        <line
          x1={padX}
          y1={zeroY}
          x2={W - padX}
          y2={zeroY}
          stroke="#E4E7E1"
          strokeWidth="1"
          strokeDasharray="3 3"
        />
      )}

      <path d={areaPath} fill={`url(#${fillId})`} />

      <polyline
        points={polyline}
        fill="none"
        stroke={lineColor}
        strokeWidth="1.5"
        strokeLinejoin="round"
        strokeLinecap="round"
      />

      <circle cx={pts[0].x} cy={pts[0].y} r={2.5} fill={lineColor} />
      <circle cx={pts[pts.length - 1].x} cy={pts[pts.length - 1].y} r={2.5} fill={lineColor} />

      {MONTH_INDICES.map((i) => (
        <text
          key={i}
          x={pts[i]?.x ?? 0}
          y={H + 14}
          textAnchor="middle"
          fill="#A8B4A8"
          style={{ fontSize: 8, fontFamily: 'inherit' }}
        >
          {MONTHS[i]}
        </text>
      ))}
    </svg>
  );
}
