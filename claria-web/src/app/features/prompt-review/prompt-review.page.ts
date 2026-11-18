import { Component, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { RouterLink } from '@angular/router';

import { ContentError, ContentService } from '../../core/content/content.service';
import { AttemptForReview } from '../../core/models/domain.models';

/**
 * Revisión docente de los intentos del Evaluador de IA. Permite corregir el
 * puntaje cuando las reglas se equivocan; el servidor recalcula si aprueba.
 */
@Component({
  imports: [FormsModule, RouterLink],
  templateUrl: './prompt-review.page.html',
})
export class PromptReviewPage {
  private readonly content = inject(ContentService);

  protected readonly attempts = signal<AttemptForReview[]>([]);
  protected readonly onlyRequired = signal(true);
  protected readonly loading = signal(true);
  protected readonly error = signal('');
  protected readonly savedId = signal<string | null>(null);

  /** Puntaje y nota que escribe el docente, por intento. */
  protected drafts: Record<string, { score: number | null; note: string }> = {};

  protected readonly visible = computed(() =>
    this.attempts().filter((a) => !this.onlyRequired() || a.lessonCode !== null),
  );

  constructor() {
    void this.load();
  }

  protected async save(attempt: AttemptForReview): Promise<void> {
    const draft = this.drafts[attempt.id];
    if (draft?.score === null || draft?.score === undefined) return;
    this.error.set('');
    try {
      await this.content.reviewAttempt(attempt.id, draft.score, draft.note);
      this.savedId.set(attempt.id);
      await this.load();
    } catch (e) {
      this.error.set(e instanceof ContentError ? e.message : 'No pudimos guardar la revisión.');
    }
  }

  private async load(): Promise<void> {
    try {
      const attempts = await this.content.getAttemptsForReview();
      this.attempts.set(attempts);
      for (const a of attempts) {
        this.drafts[a.id] ??= { score: a.reviewedScore ?? a.score, note: a.reviewNote ?? '' };
      }
    } catch {
      this.error.set('No pudimos cargar los intentos.');
    } finally {
      this.loading.set(false);
    }
  }
}
