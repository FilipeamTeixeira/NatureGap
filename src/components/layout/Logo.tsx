import Image from 'next/image';
import logoFull from '../../../public/naturegap-logo.png';
import logoMark from '../../../public/naturegap-logo-simple.png';

interface LogoProps {
  /** Rendered height in px. Width follows the artwork's aspect ratio. */
  size?: number;
  className?: string;
}

/** Icon-only mark (no wordmark). Use where "NatureGap" is already written out. */
export function LogoMark({ size = 28, className }: LogoProps) {
  return (
    <Image
      src={logoMark}
      alt=""
      aria-hidden
      width={size}
      height={size}
      priority
      className={className}
      style={{ width: size, height: size }}
    />
  );
}

/** Full lockup: mark plus the NATUREGAP wordmark and tagline. */
export function LogoFull({ size = 96, className }: LogoProps) {
  const width = Math.round((size * logoFull.width) / logoFull.height);
  return (
    <Image
      src={logoFull}
      alt="NatureGap — making space for nature"
      width={width}
      height={size}
      priority
      className={className}
      style={{ width, height: size }}
    />
  );
}
