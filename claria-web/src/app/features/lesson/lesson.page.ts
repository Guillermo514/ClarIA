import { Component, computed, inject, input, signal } from '@angular/core';
import { Router, RouterLink } from '@angular/router';

import { AuthService } from '../../core/auth/auth.service';
import { ContentError, ContentService } from '../../core/content/content.service';
import { createCountdown } from '../../core/content/countdown';
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
  /** Tiempo mínimo de lectura que falta (lo calcula el servidor). */
  protected readonly countdown = createCountdown();

  protected readonly gamesPending = computed(
    () => this.lesson()?.activities.some((a) => !a.completed) ?? false,
  );
  protected readonly cardsPending = computed(() => {
    const lesson = this.lesson();
    return lesson ? lesson.cardsSeen < lesson.cardsTotal : false;
  });
  protected readonly articlePending = computed(() => !(this.lesson()?.articleRead ?? true));
  protected readonly missionPending = computed(() => {
    const mission = this.lesson()?.mission;
    return mission ? !mission.passed : false;
  });
  /** Lo que falta para completar la lección, p. ej. «Lectura 0:42 · Lee el artículo». */
  protected readonly pendingLabel = computed(() =>
    [
      this.countdown.remaining() > 0 ? `Lectura ${this.countdown.label()}` : null,
      this.gamesPending() ? 'Termina el juego' : null,
      this.cardsPending() ? 'Voltea las flashcards' : null,
      this.articlePending() ? 'Lee el artículo' : null,
      this.missionPending() ? 'Aprueba la misión del evaluador' : null,
    ]
      .filter(Boolean)
      .join(' · '),
  );
  /** Docentes y administradores no tienen requisitos (igual que en el servidor). */
  private readonly isStaff = inject(AuthService).isStaff;
  protected readonly canComplete = computed(
    () =>
      this.isStaff() ||
      (this.countdown.remaining() <= 0 &&
        !this.gamesPending() &&
        !this.cardsPending() &&
        !this.articlePending() &&
        !this.missionPending()),
  );

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
    } catch (e) {
      this.error.set(
        e instanceof ContentError ? e.message : 'No pudimos guardar tu avance. Inténtalo de nuevo.',
      );
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
    this.error.set('');
    this.state.set('ready');

    if (!lesson.completed) {
      try {
        this.countdown.start((await this.content.startLesson(lesson.id)).secondsRemaining);
      } catch (e) {
        this.error.set(e instanceof ContentError ? e.message : 'No pudimos registrar tu lectura.');
      }
    }
    window.scrollTo({ top: 0 });
  }

  /** El juego avisó que se terminó: se actualiza para habilitar «Marcar como completada». */
  protected markGameDone(activityId: string): void {
    const lesson = this.lesson();
    if (!lesson) return;
    this.lesson.set({
      ...lesson,
      activities: lesson.activities.map((a) =>
        a.id === activityId ? { ...a, completed: true } : a,
      ),
    });
  }

  protected goToQuiz(): void {
    void this.router.navigate(['/evaluaciones', this.nivel()]);
  }
}
