interface ScoreGaugeProps {
  score: number;
  min?: number;
  max?: number;
}

function polar(cx: number, cy: number, r: number, deg: number) {
  const rad = (deg * Math.PI) / 180;
  return { x: cx + r * Math.cos(rad), y: cy - r * Math.sin(rad) };
}

function gaugeColor(score: number): string {
  if (score <= -20) return '#C95B4B';
  if (score <= -10) return '#E8A44C';
  if (score < 5)   return '#E8A44C';
  if (score < 15)  return '#73A56D';
  return '#2E6F40';
}

export default function ScoreGauge({ score, min = -50, max = 50 }: ScoreGaugeProps) {
  const cx = 100;
  const cy = 108;
  const r = 78;

  const clamped = Math.max(min, Math.min(max, score));
  const pct = (clamped - min) / (max - min);
  const angleDeg = 180 - pct * 180;

  const start  = polar(cx, cy, r, 180);
  const end    = polar(cx, cy, r, 0);
  const needle = polar(cx, cy, r, angleDeg);

  const arcSpan = 180 - angleDeg;
  const largeArc = arcSpan > 180 ? 1 : 0;
  const hasFill = Math.abs(pct) > 0.005;

  const color = gaugeColor(clamped);
  const label = score > 0 ? `+${score}` : String(score);

  return (
    <svg viewBox="0 0 200 125" className="w-40 flex-shrink-0">
      {/* Gray track */}
      <path
        d={`M ${start.x} ${start.y} A ${r} ${r} 0 0 1 ${end.x} ${end.y}`}
        fill="none"
        stroke="#F0F2EE"
        strokeWidth="10"
        strokeLinecap="round"
      />

      {/* Colored fill */}
      {hasFill && (
        <path
          d={`M ${start.x} ${start.y} A ${r} ${r} 0 ${largeArc} 1 ${needle.x} ${needle.y}`}
          fill="none"
          stroke={color}
          strokeWidth="10"
          strokeLinecap="round"
        />
      )}

      {/* Needle dot */}
      <circle cx={needle.x} cy={needle.y} r={7} fill={color} stroke="white" strokeWidth="2.5" />

      {/* Score value */}
      <text
        x={cx}
        y={cy - 16}
        textAnchor="middle"
        fill={color}
        style={{ fontSize: 28, fontWeight: 700, fontFamily: 'inherit' }}
      >
        {label}
      </text>
      <text
        x={cx}
        y={cy - 2}
        textAnchor="middle"
        fill="#667066"
        style={{ fontSize: 9, fontFamily: 'inherit' }}
      >
        Impact score
      </text>

      {/* Range labels */}
      <text
        x={start.x + 2}
        y={cy + 14}
        textAnchor="start"
        fill="#A8B4A8"
        style={{ fontSize: 8, fontFamily: 'inherit' }}
      >
        {min}
      </text>
      <text
        x={end.x - 2}
        y={cy + 14}
        textAnchor="end"
        fill="#A8B4A8"
        style={{ fontSize: 8, fontFamily: 'inherit' }}
      >
        +{max}
      </text>
    </svg>
  );
}
