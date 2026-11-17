import { Component, inject, signal } from '@angular/core';
import { RouterLink } from '@angular/router';

import { AuthService } from '../../core/auth/auth.service';
import { ContentService } from '../../core/content/content.service';
import { MedalComponent } from '../../shared/components/medal/medal.component';

/** Niveles del grupo de edad del estudiante, con su avance y desbloqueo. */
@Component({
  imports: [RouterLink, MedalComponent],
  templateUrl: './courses.page.html',
})
export class CoursesPage {
  private readonly content = inject(ContentService);

  protected readonly levels = this.content.levels;
  protected readonly isStaff = inject(AuthService).isStaff;
  protected readonly error = signal('');

  constructor() {
    this.content.refreshLevels().catch(() => this.error.set('No pudimos cargar tus niveles.'));
  }

  protected percent(completed: number, total: number): number {
    return total ? Math.round((completed / total) * 100) : 0;
  }
}
