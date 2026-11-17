import { Component, input } from '@angular/core';

/**
 * Medalla de un nivel. Si el nivel aún no tiene icono (niveles 9 a 12), muestra
 * uno genérico. Las medallas no obtenidas se ven en gris.
 */
@Component({
  selector: 'app-medal',
  template: `
    @if (icon(); as src) {
      <img [src]="src" alt="" loading="lazy" width="96" height="96" />
    } @else {
      <span class="medal-fallback" aria-hidden="true">🏅</span>
    }
  `,
  host: {
    class: 'medal',
    '[class.earned]': 'earned()',
    '[class.small]': "size() === 'small'",
  },
})
export class MedalComponent {
  readonly icon = input<string | null>(null);
  readonly earned = input(false);
  readonly size = input<'small' | 'normal'>('normal');
}
