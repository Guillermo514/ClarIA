import { Component, computed, inject, input, signal } from '@angular/core';
import { RouterLink } from '@angular/router';

import { ContentError, ContentService } from '../../core/content/content.service';
import { LevelSummary, Quiz, QuizResult } from '../../core/models/domain.models';
import { LevelRequirementsComponent } from '../../shared/components/level-requirements/level-requirements.component';
import { MedalComponent } from '../../shared/components/medal/medal.component';

type QuizState =
  'loading' | 'locked' | 'missing' | 'requirements' | 'answering' | 'sending' | 'result';

/**
 * Evaluación final de un nivel. El estudiante responde todas las preguntas y la
 * base de datos califica (las respuestas correctas nunca llegan al navegador antes).
 */
@Component({
  imports: [RouterLink, MedalComponent, LevelRequirementsComponent],
  templateUrl: './quiz.page.html',
})
export class QuizPage {
  private readonly content = inject(ContentService);

  /** Parámetro de la ruta /evaluaciones/:nivel. */
  readonly nivel = input.required<string>();

  protected readonly state = signal<QuizState>('loading');
  protected readonly level = signal<LevelSummary | null>(null);
  protected readonly quiz = signal<Quiz | null>(null);
  protected readonly index = signal(0);
  /** Opción elegida por pregunta (id de pregunta → id de opción). */
  protected readonly choices = signal<Record<string, string>>({});
  protected readonly result = signal<QuizResult | null>(null);
  protected readonly error = signal('');

  protected readonly question = computed(() => this.quiz()?.questions[this.index()] ?? null);
  protected readonly total = computed(() => this.quiz()?.questions.length ?? 0);
  protected readonly isLast = computed(() => this.index() === this.total() - 1);
  protected readonly choice = computed(() => {
    const question = this.question();
    return question ? (this.choices()[question.id] ?? null) : null;
  });

  protected readonly nextLevel = computed(() => {
    const current = this.level();
    return current
      ? (this.content.levels().find((l) => l.levelNumber === current.levelNumber + 1) ?? null)
      : null;
  });

  protected readonly resultIcon = computed(() => {
    const score = this.result()?.score ?? 0;
    if (score === 100) return '🏆';
    return this.result()?.passed ? '🌟' : '💪';
  });

  protected readonly resultTitle = computed(() => {
    const result = this.result();
    if (!result) return '';
    if (result.score === 100) return '¡Criterio impecable!';
    return result.passed ? '¡Nivel aprobado!' : '¡Sigue practicando!';
  });

  ngOnChanges(): void {
    void this.load();
  }

  protected choose(optionId: string): void {
    const question = this.question();
    if (question) this.choices.update((all) => ({ ...all, [question.id]: optionId }));
  }

  protected previous(): void {
    this.index.update((i) => Math.max(0, i - 1));
  }

  protected async next(): Promise<void> {
    if (!this.isLast()) {
      this.index.update((i) => i + 1);
      return;
    }
    await this.submit();
  }

  protected restart(): void {
    this.choices.set({});
    this.index.set(0);
    this.result.set(null);
    this.state.set('answering');
  }

  /** Para la revisión: ¿la opción es la correcta / la que eligió el estudiante? */
  protected isCorrectOption(questionId: string, optionId: string): boolean {
    return (
      this.result()
        ?.results.find((r) => r.questionId === questionId)
        ?.correctOptionIds.includes(optionId) ?? false
    );
  }

  protected wasAnsweredRight(questionId: string): boolean {
    return this.result()?.results.find((r) => r.questionId === questionId)?.correct ?? false;
  }

  private async submit(): Promise<void> {
    const quiz = this.quiz();
    if (!quiz) return;

    this.state.set('sending');
    this.error.set('');
    try {
      const answers = quiz.questions.map((q) => ({
        questionId: q.id,
        optionIds: this.choices()[q.id] ? [this.choices()[q.id]] : [],
      }));
      this.result.set(await this.content.submitQuiz(quiz.id, answers));
      this.state.set('result');
      window.scrollTo({ top: 0 });
    } catch (e) {
      this.error.set(
        e instanceof ContentError
          ? e.message
          : 'No pudimos enviar tu evaluación. Revisa tu conexión e inténtalo de nuevo.',
      );
      this.state.set('answering');
    }
  }

  private async load(): Promise<void> {
    this.state.set('loading');
    await this.content.refreshLevels();
    const level = await this.content.getLevel(Number(this.nivel()));
    this.level.set(level);
    if (!level) {
      this.state.set('missing');
      return;
    }
    if (!level.unlocked) {
      this.state.set('locked');
      return;
    }
    if (!level.quizReady) {
      this.state.set('requirements');
      return;
    }

    const quiz = await this.content.getQuiz(level.id);
    if (!quiz || !quiz.questions.length) {
      this.state.set('missing');
      return;
    }
    this.quiz.set(quiz);
    this.restart();
  }
}
