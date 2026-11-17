import { Component, DestroyRef, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { ActivatedRoute, RouterLink } from '@angular/router';

import { ContentError, ContentService } from '../../core/content/content.service';
import { Mission, PromptEvaluation } from '../../core/models/domain.models';

/** Espera tras dejar de escribir antes de pedir la vista previa al servidor. */
const PREVIEW_DELAY_MS = 500;
const MAX_LENGTH = 4000;

/** Estructura sugerida a partir de los 5 ingredientes (lección 5.3). */
const BASIC_TEMPLATE = `Actúa como [rol: un experto en el tema].
[Contexto: quién eres, para qué lo necesitas y para quién es.]
[Tarea: usa un verbo de acción, p. ej. «Explica…», «Compara…», «Hazme 5 preguntas…».]
[Formato: en una tabla, en 5 puntos, en menos de 100 palabras…]
Por ejemplo: [una muestra breve de cómo quieres la respuesta].`;

/** La rúbrica avanzada agrega técnicas de la lección 7.1. */
const ADVANCED_EXTRA = `
Antes de responder, hazme 3 preguntas para entender mejor lo que necesito.
No inventes datos: si no estás seguro, dilo.`;

/**
 * Evaluador de prompts: califica con reglas en el servidor (rúbrica por edad),
 * muestra la retroalimentación por criterio y registra los intentos de misión.
 */
@Component({
  imports: [FormsModule, RouterLink],
  templateUrl: './prompt-evaluator.page.html',
})
export class PromptEvaluatorPage {
  private readonly content = inject(ContentService);
  private readonly route = inject(ActivatedRoute);

  protected readonly maxLength = MAX_LENGTH;
  protected readonly missions = signal<Mission[]>([]);
  /** null = modo libre. */
  protected readonly selectedId = signal<string | null>(null);
  protected readonly text = signal('');
  protected readonly evaluation = signal<PromptEvaluation | null>(null);
  protected readonly lastAttempt = signal<PromptEvaluation | null>(null);
  protected readonly evaluating = signal(false);
  protected readonly sending = signal(false);
  protected readonly showTemplate = signal(false);
  protected readonly loading = signal(true);
  protected readonly error = signal('');

  protected readonly mission = computed(
    () => this.missions().find((m) => m.id === this.selectedId()) ?? null,
  );
  protected readonly template = computed(() =>
    this.evaluation()?.rubric === 'avanzada' ? BASIC_TEMPLATE + ADVANCED_EXTRA : BASIC_TEMPLATE,
  );
  /** Mejora del primer intento al mejor. */
  protected readonly improvement = computed(() => {
    const attempts = this.mission()?.attempts ?? [];
    if (attempts.length < 2) return null;
    const best = Math.max(...attempts.map((a) => a.score));
    return { first: attempts[0].score, best, diff: best - attempts[0].score };
  });

  private previewTimer: ReturnType<typeof setTimeout> | undefined;
  private previewId = 0;

  constructor() {
    inject(DestroyRef).onDestroy(() => clearTimeout(this.previewTimer));
    void this.load();
  }

  protected select(missionId: string | null): void {
    this.selectedId.set(missionId);
    this.lastAttempt.set(null);
    this.error.set('');
    this.schedulePreview();
  }

  protected onTextChange(value: string): void {
    this.text.set(value);
    this.lastAttempt.set(null);
    this.schedulePreview();
  }

  protected useTemplate(): void {
    this.onTextChange(this.template());
    this.showTemplate.set(false);
  }

  protected async submit(): Promise<void> {
    const mission = this.mission();
    if (!mission) return;

    this.sending.set(true);
    this.error.set('');
    try {
      const result = await this.content.submitPromptAttempt(mission.id, this.text());
      this.evaluation.set(result);
      this.lastAttempt.set(result);
      this.missions.set(await this.content.getMissions());
    } catch (e) {
      this.error.set(e instanceof ContentError ? e.message : 'No pudimos enviar tu intento.');
    } finally {
      this.sending.set(false);
    }
  }

  protected levelIcon(level: string): string {
    return level === 'strong' ? '✓' : level === 'partial' ? '◐' : '✗';
  }

  /** Vista previa: se pide al servidor un momento después de dejar de escribir. */
  private schedulePreview(): void {
    clearTimeout(this.previewTimer);
    const text = this.text().trim();
    if (text.length < 3) {
      this.evaluation.set(null);
      return;
    }
    this.previewTimer = setTimeout(() => void this.preview(text), PREVIEW_DELAY_MS);
  }

  private async preview(text: string): Promise<void> {
    const id = ++this.previewId;
    this.evaluating.set(true);
    try {
      const result = await this.content.evaluatePrompt(text, this.selectedId());
      if (id === this.previewId) this.evaluation.set(result);
    } catch (e) {
      if (id === this.previewId)
        this.error.set(e instanceof ContentError ? e.message : 'No pudimos evaluar tu prompt.');
    } finally {
      if (id === this.previewId) this.evaluating.set(false);
    }
  }

  private async load(): Promise<void> {
    try {
      const missions = await this.content.getMissions();
      this.missions.set(missions);
      // /evaluador?mision=<id> abre directamente esa misión (desde las lecciones).
      const requested = this.route.snapshot.queryParamMap.get('mision');
      const first = missions.find((m) => m.id === requested) ?? missions.find((m) => !m.passed);
      this.selectedId.set(first?.id ?? null);
    } catch {
      this.error.set('No pudimos cargar las misiones.');
    } finally {
      this.loading.set(false);
    }
  }
}
