import { Component, computed, inject, input, signal } from '@angular/core';
import { Router, RouterLink } from '@angular/router';

import { ContentService } from '../../core/content/content.service';
import { LessonDetail, LessonSummary } from '../../core/models/domain.models';
import { GameEmbedComponent } from '../../shared/components/game-embed/game-embed.component';
import { TextBlocksComponent } from '../../shared/components/text-blocks/text-blocks.component';

/** Lectura de una lección con su juego, fuente y artículo relacionado. */
@Component({
  imports: [RouterLink, GameEmbedComponent, TextBlocksComponent],
  templateUrl: './lesson.page.html',
})
export class LessonPage {
  private readonly content = inject(ContentService);
  private readonly router = inject(Router);

  /** Parámetros de la ruta /cursos/:nivel/leccion/:codigo. */
  readonly nivel = input.required<string>();
  readonly codigo = input.required<string>();

  protected readonly lesson = signal<LessonDetail | null>(null);
  protected readonly siblings = signal<LessonSummary[]>([]);
  protected readonly state = signal<'loading' | 'ready' | 'locked' | 'missing'>('loading');
  protected readonly saving = signal(false);
  protected readonly error = signal('');

  protected readonly next = computed(() => {
    const list = this.siblings();
    const index = list.findIndex((l) => l.code === this.lesson()?.code);
    return index >= 0 ? (list[index + 1] ?? null) : null;
  });
  protected readonly previous = computed(() => {
    const list = this.siblings();
    const index = list.findIndex((l) => l.code === this.lesson()?.code);
    return index > 0 ? list[index - 1] : null;
  });

  ngOnChanges(): void {
    void this.load();
  }

  protected async complete(): Promise<void> {
    const lesson = this.lesson();
    if (!lesson) return;

    this.saving.set(true);
    this.error.set('');
    try {
      await this.content.completeLesson(lesson.id);
      this.lesson.set({ ...lesson, completed: true });
      this.siblings.update((list) =>
        list.map((l) => (l.id === lesson.id ? { ...l, completed: true } : l)),
      );
    } catch {
      this.error.set('No pudimos guardar tu avance. Inténtalo de nuevo.');
    } finally {
      this.saving.set(false);
    }
  }

  private async load(): Promise<void> {
    this.state.set('loading');
    const level = await this.content.getLevel(Number(this.nivel()));
    if (!level) {
      this.state.set('missing');
      return;
    }
    if (!level.unlocked) {
      this.state.set('locked');
      return;
    }

    const [lesson, siblings] = await Promise.all([
      this.content.getLesson(this.codigo()),
      this.content.getLessons(level.id),
    ]);
    if (!lesson || lesson.courseId !== level.id) {
      this.state.set('missing');
      return;
    }
    this.lesson.set(lesson);
    this.siblings.set(siblings);
    this.state.set('ready');
    window.scrollTo({ top: 0 });
  }

  protected goToQuiz(): void {
    void this.router.navigate(['/evaluaciones', this.nivel()]);
  }
}
