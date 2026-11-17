import { Component, inject, signal } from '@angular/core';
import { RouterLink } from '@angular/router';

import { ContentService } from '../../core/content/content.service';
import { MedalComponent } from '../../shared/components/medal/medal.component';

/** Evaluaciones finales de los niveles del estudiante. */
@Component({
  imports: [RouterLink, MedalComponent],
  templateUrl: './evaluations.page.html',
})
export class EvaluationsPage {
  private readonly content = inject(ContentService);

  protected readonly levels = this.content.levels;
  protected readonly error = signal('');

  constructor() {
    this.content.refreshLevels().catch(() => this.error.set('No pudimos cargar tus evaluaciones.'));
  }
}
