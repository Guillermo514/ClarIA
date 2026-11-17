import { Component, inject, signal } from '@angular/core';

import { ContentService } from '../../core/content/content.service';
import { MedalComponent } from '../../shared/components/medal/medal.component';

/** Medallas de los niveles del estudiante: obtenidas y por obtener. */
@Component({
  imports: [MedalComponent],
  templateUrl: './achievements.page.html',
})
export class AchievementsPage {
  private readonly content = inject(ContentService);

  protected readonly levels = this.content.levels;
  protected readonly error = signal('');

  constructor() {
    this.content.refreshLevels().catch(() => this.error.set('No pudimos cargar tus medallas.'));
  }
}
