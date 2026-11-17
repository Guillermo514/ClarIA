import { Component, computed, inject } from '@angular/core';
import { RouterLink } from '@angular/router';

import { AuthService } from '../../core/auth/auth.service';
import { ContentService } from '../../core/content/content.service';

/** Panel de inicio con bienvenida, avance del nivel actual y siguiente reto. */
@Component({
  imports: [RouterLink],
  templateUrl: './home.page.html',
})
export class HomePage {
  private readonly auth = inject(AuthService);
  private readonly content = inject(ContentService);

  protected readonly initials = this.auth.initials;
  protected readonly firstName = computed(() => this.auth.displayName().split(/\s+/)[0]);

  protected readonly levels = this.content.levels;
  protected readonly current = this.content.currentLevel;
  protected readonly medals = computed(() => this.levels().filter((l) => l.medalEarned).length);
  protected readonly lessonsDone = computed(() =>
    this.levels().reduce((sum, l) => sum + l.lessonsCompleted, 0),
  );
  protected readonly lessonsTotal = computed(() =>
    this.levels().reduce((sum, l) => sum + l.lessonsTotal, 0),
  );
  protected readonly currentPercent = computed(() => {
    const level = this.current();
    return level?.lessonsTotal
      ? Math.round((level.lessonsCompleted / level.lessonsTotal) * 100)
      : 0;
  });

  constructor() {
    void this.content.refreshLevels().catch(() => undefined);
  }
}
