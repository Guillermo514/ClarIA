import { Component, inject, input, signal } from '@angular/core';
import { RouterLink } from '@angular/router';

import { ContentService } from '../../core/content/content.service';
import { LessonSummary, LevelSummary } from '../../core/models/domain.models';
import { LevelRequirementsComponent } from '../../shared/components/level-requirements/level-requirements.component';
import { MedalComponent } from '../../shared/components/medal/medal.component';

/** Un nivel: sus lecciones en orden y el acceso a su evaluación final. */
@Component({
  imports: [RouterLink, MedalComponent, LevelRequirementsComponent],
  templateUrl: './level.page.html',
})
export class LevelPage {
  private readonly content = inject(ContentService);

  /** Parámetro de la ruta /cursos/:nivel. */
  readonly nivel = input.required<string>();

  protected readonly level = signal<LevelSummary | null>(null);
  protected readonly lessons = signal<LessonSummary[]>([]);
  protected readonly state = signal<'loading' | 'ready' | 'locked' | 'missing'>('loading');

  ngOnChanges(): void {
    void this.load();
  }

  private async load(): Promise<void> {
    await this.content.refreshLevels();
    const level = await this.content.getLevel(Number(this.nivel()));
    if (!level) {
      this.state.set('missing');
      return;
    }
    this.level.set(level);
    if (!level.unlocked) {
      this.state.set('locked');
      return;
    }
    this.lessons.set(await this.content.getLessons(level.id));
    this.state.set('ready');
  }
}
