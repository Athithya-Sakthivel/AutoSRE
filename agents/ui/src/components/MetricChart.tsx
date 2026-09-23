/**
 * Pure SVG chart components with no charting-library dependency.
 *
 * Components:
 *   LineChart          - time-series line with area fill
 *   BarChart           - time-series vertical bars
 *   HorizontalBarChart - category breakdown horizontal bars
 */

import type { ReactElement, ReactNode } from "react";

interface ChartMargins {
  top: number;
  right: number;
  bottom: number;
  left: number;
}

const DEFAULT_MARGINS: ChartMargins = {
  top: 8,
  right: 12,
  bottom: 24,
  left: 48,
};

const CHART_COLORS: Record<string, string> = {
  "status-running": "#5b9bd5",
  "status-awaiting": "#d4a843",
  "status-resolved": "#5bb98a",
  "status-failed": "#d45b5b",
  "status-complete": "#7a7f8a",
  "severity-1": "#d45b5b",
  "severity-2": "#d4a843",
  "severity-3": "#d4c843",
  "severity-4": "#5b9bd5",
};

const CHART_WIDTH = 400;
const DEFAULT_HEIGHT = 180;

function colorToHex(color: string): string {
  return CHART_COLORS[color] ?? "#5b9bd5";
}

function normalizeChartHeight(height: number): number {
  if (!Number.isFinite(height)) {
    return DEFAULT_HEIGHT;
  }

  return Math.max(120, Math.trunc(height));
}

function normalizeNumericValue(value: number): number {
  return Number.isFinite(value) ? value : 0;
}

function formatAxisNumber(value: number): string {
  if (!Number.isFinite(value) || value === 0) {
    return "0";
  }

  if (Math.abs(value) >= 1000) {
    return `${(value / 1000).toFixed(1)}k`;
  }

  if (Math.abs(value) < 1) {
    return value.toFixed(2);
  }

  if (Math.abs(value) < 10) {
    return value.toFixed(1);
  }

  return Math.round(value).toString();
}

function formatShortTime(iso: string): string {
  const date = new Date(iso);

  if (Number.isNaN(date.getTime())) {
    return "";
  }

  const hour = date.getHours();
  const minute = date.getMinutes();

  if (hour === 0 && minute === 0) {
    return date.getDate().toString();
  }

  return `${hour.toString().padStart(2, "0")}:${minute
    .toString()
    .padStart(2, "0")}`;
}

function getLabelIndexes(length: number): number[] {
  if (length <= 0) {
    return [];
  }

  if (length === 1) {
    return [0];
  }

  return [0, Math.floor((length - 1) / 2), length - 1].filter(
    (value, index, values) => values.indexOf(value) === index,
  );
}

function ChartContainer({
  children,
  height = DEFAULT_HEIGHT,
  label,
}: {
  children: ReactNode;
  height?: number;
  label?: string | undefined;
}): ReactElement {
  const accessibleLabel = label?.trim() || "Metric chart";
  const chartHeight = normalizeChartHeight(height);

  return (
    <div
      className="rounded-lg border border-surface-border bg-surface-1 p-4"
      role="img"
      aria-label={accessibleLabel}
    >
      <svg
        viewBox={`0 0 ${CHART_WIDTH} ${chartHeight}`}
        className="h-auto w-full"
        preserveAspectRatio="xMidYMid meet"
        aria-hidden="true"
      >
        {children}
      </svg>
    </div>
  );
}

function ChartEmpty({ message }: { message: string }): ReactElement {
  return (
    <div className="flex h-44 items-center justify-center rounded-lg border border-dashed border-surface-border bg-surface-1/30 text-xs text-slate-500">
      {message}
    </div>
  );
}

// ---------------------------------------------------------------------------
// LineChart
// ---------------------------------------------------------------------------

export interface LineChartProps {
  data: Array<{
    timestamp: string;
    value: number;
  }>;
  label?: string;
  color?: string;
  yFormat?: (value: number) => string;
  height?: number;
}

export function LineChart({
  data,
  label,
  color = "status-running",
  yFormat = formatAxisNumber,
  height = DEFAULT_HEIGHT,
}: LineChartProps): ReactElement {
  if (data.length === 0) {
    return <ChartEmpty message="No data for selected range" />;
  }

  const chartHeight = normalizeChartHeight(height);
  const m = DEFAULT_MARGINS;
  const plotW = CHART_WIDTH - m.left - m.right;
  const plotH = Math.max(1, chartHeight - m.top - m.bottom);

  const series = data.map((item) => ({
    ...item,
    value: normalizeNumericValue(item.value),
  }));

  const values = series.map((item) => item.value);
  const maxVal = Math.max(...values, 0);
  const minVal = Math.min(...values, 0);
  const valueRange = maxVal - minVal || 1;

  const points = series.map((item, index) => {
    const x = m.left + (index / Math.max(series.length - 1, 1)) * plotW;

    const y = m.top + plotH - ((item.value - minVal) / valueRange) * plotH;

    return {
      x,
      y,
      ...item,
    };
  });

  const firstPoint = points[0];
  const lastPoint = points[points.length - 1];

  if (!firstPoint || !lastPoint) {
    return <ChartEmpty message="No data for selected range" />;
  }

  const pathD = points
    .map((point, index) => `${index === 0 ? "M" : "L"} ${point.x} ${point.y}`)
    .join(" ");

  const areaD = `${pathD} L ${lastPoint.x} ${
    m.top + plotH
  } L ${firstPoint.x} ${m.top + plotH} Z`;

  const hex = colorToHex(color);

  const yTicks = [0, 0.33, 0.66, 1].map((ratio) => ({
    val: minVal + ratio * valueRange,
    y: m.top + plotH - ratio * plotH,
  }));

  const xLabelIndexes = getLabelIndexes(series.length);

  return (
    <ChartContainer height={chartHeight} label={label}>
      {yTicks.map((tick) => (
        <line
          key={`grid-${tick.y}`}
          x1={m.left}
          x2={CHART_WIDTH - m.right}
          y1={tick.y}
          y2={tick.y}
          stroke="oklch(0.28 0.01 260)"
          strokeWidth={0.5}
          strokeDasharray="2,2"
        />
      ))}

      <path d={areaD} fill={hex} fillOpacity={0.1} />

      <path d={pathD} fill="none" stroke={hex} strokeWidth={2} />

      {points.map((point) => (
        <circle
          key={`point-${point.timestamp}-${point.x}`}
          cx={point.x}
          cy={point.y}
          r={2.5}
          fill={hex}
        />
      ))}

      {yTicks.map((tick) => (
        <text
          key={`y-label-${tick.val}`}
          x={m.left - 6}
          y={tick.y + 3}
          textAnchor="end"
          className="fill-slate-500"
          style={{ fontSize: "9px" }}
        >
          {yFormat(tick.val)}
        </text>
      ))}

      {xLabelIndexes.map((index) => {
        const item = series[index];

        if (!item) {
          return null;
        }

        const x = m.left + (index / Math.max(series.length - 1, 1)) * plotW;

        return (
          <text
            key={`x-label-${item.timestamp}-${x}`}
            x={x}
            y={chartHeight - 6}
            textAnchor="middle"
            className="fill-slate-500"
            style={{ fontSize: "9px" }}
          >
            {formatShortTime(item.timestamp)}
          </text>
        );
      })}
    </ChartContainer>
  );
}

// ---------------------------------------------------------------------------
// BarChart
// ---------------------------------------------------------------------------

export interface BarChartProps {
  data: Array<{
    timestamp: string;
    value: number;
  }>;
  label?: string;
  color?: string;
  height?: number;
}

export function BarChart({
  data,
  label,
  color = "status-running",
  height = DEFAULT_HEIGHT,
}: BarChartProps): ReactElement {
  if (data.length === 0) {
    return <ChartEmpty message="No data for selected range" />;
  }

  const chartHeight = normalizeChartHeight(height);
  const m = DEFAULT_MARGINS;
  const plotW = CHART_WIDTH - m.left - m.right;
  const plotH = Math.max(1, chartHeight - m.top - m.bottom);

  const series = data.map((item) => ({
    ...item,
    value: Math.max(0, normalizeNumericValue(item.value)),
  }));

  const maxVal = Math.max(...series.map((item) => item.value), 1);

  const slotWidth = plotW / series.length;
  const barWidth = Math.max(2, slotWidth * 0.7);
  const gap = slotWidth - barWidth;
  const hex = colorToHex(color);

  const yTicks = [0, 0.5, 1].map((ratio) => ({
    val: ratio * maxVal,
    y: m.top + plotH - ratio * plotH,
  }));

  const xLabelIndexes = getLabelIndexes(series.length);

  return (
    <ChartContainer height={chartHeight} label={label}>
      {yTicks.map((tick) => (
        <line
          key={`grid-${tick.y}`}
          x1={m.left}
          x2={CHART_WIDTH - m.right}
          y1={tick.y}
          y2={tick.y}
          stroke="oklch(0.28 0.01 260)"
          strokeWidth={0.5}
          strokeDasharray="2,2"
        />
      ))}

      {series.map((item, index) => {
        const barH = (item.value / maxVal) * plotH;

        const x = m.left + index * slotWidth + gap / 2;

        const y = m.top + plotH - barH;

        return (
          <rect
            key={`bar-${x}`}
            x={x}
            y={y}
            width={barWidth}
            height={barH}
            fill={hex}
            rx={1}
          />
        );
      })}

      {yTicks.map((tick) => (
        <text
          key={`y-label-${tick.val}`}
          x={m.left - 6}
          y={tick.y + 3}
          textAnchor="end"
          className="fill-slate-500"
          style={{ fontSize: "9px" }}
        >
          {formatAxisNumber(tick.val)}
        </text>
      ))}

      {xLabelIndexes.map((index) => {
        const item = series[index];

        if (!item) {
          return null;
        }

        const x = m.left + index * slotWidth + gap / 2 + barWidth / 2;

        return (
          <text
            key={`x-label-${item.timestamp}-${x}`}
            x={x}
            y={chartHeight - 6}
            textAnchor="middle"
            className="fill-slate-500"
            style={{ fontSize: "9px" }}
          >
            {formatShortTime(item.timestamp)}
          </text>
        );
      })}
    </ChartContainer>
  );
}

// ---------------------------------------------------------------------------
// HorizontalBarChart
// ---------------------------------------------------------------------------

export interface HorizontalBarProps {
  data: Array<{
    category: string;
    count: number;
  }>;
  label?: string;
  color?: string;
  maxItems?: number;
}

export function HorizontalBarChart({
  data,
  label,
  color = "status-running",
  maxItems = 8,
}: HorizontalBarProps): ReactElement {
  const safeMaxItems = Number.isFinite(maxItems)
    ? Math.max(1, Math.trunc(maxItems))
    : 8;

  const sorted = data
    .map((item) => ({
      category: item.category,
      count: Number.isFinite(item.count) ? Math.max(0, item.count) : 0,
    }))
    .sort((a, b) => b.count - a.count)
    .slice(0, safeMaxItems);

  if (sorted.length === 0) {
    return <ChartEmpty message="No category data" />;
  }

  const maxCount = Math.max(...sorted.map((item) => item.count), 1);

  const hex = colorToHex(color);
  const rowH = 28;
  const chartHeight = sorted.length * rowH + 16;
  const labelW = 120;
  const barAreaW = Math.max(1, CHART_WIDTH - labelW - 16);

  return (
    <ChartContainer height={chartHeight} label={label}>
      {sorted.map((item, index) => {
        const y = index * rowH + 8;
        const barW = (item.count / maxCount) * barAreaW;

        const displayCategory =
          item.category.length > 16
            ? `${item.category.slice(0, 15)}…`
            : item.category;

        return (
          <g key={`${item.category}-${item.count}-${barW}`}>
            <text
              x={labelW - 8}
              y={y + rowH / 2 + 3}
              textAnchor="end"
              className="fill-slate-400"
              style={{ fontSize: "10px" }}
            >
              {displayCategory}
            </text>

            <rect
              x={labelW}
              y={y + 4}
              width={barW}
              height={rowH - 10}
              fill={hex}
              rx={2}
            />

            <text
              x={labelW + barW + 6}
              y={y + rowH / 2 + 3}
              className="fill-slate-300"
              style={{
                fontSize: "10px",
                fontWeight: 600,
              }}
            >
              {item.count}
            </text>
          </g>
        );
      })}
    </ChartContainer>
  );
}
