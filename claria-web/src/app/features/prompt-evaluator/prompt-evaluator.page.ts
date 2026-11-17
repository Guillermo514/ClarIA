import { Component, DestroyRef, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { ActivatedRoute, RouterLink } from '@angular/router';

import { AuthService } from '../../core/auth/auth.service';
import { ContentError, ContentService } from '../../core/content/content.service';
import {
  Mission,
  PromptEvaluation,
  PromptField,
  PromptFields,
  PromptRubric,
} from '../../core/models/domain.models';

/** Espera tras dejar de escribir antes de pedir la vista previa al servidor. */
const PREVIEW_DELAY_MS = 600;

/** Ejemplos que se muestran dentro de cada campo vacío. */
const PLACEHOLDERS: Record<string, string> = {
  rol: 'Ej.: Actúa como un profesor de historia de secundaria',
  contexto: 'Ej.: Estoy preparando una exposición para mis compañeros de 13 años',
  tarea: 'Ej.: Explica las tres causas principales de…',
  formato: 'Ej.: En una tabla con 3 columnas, en menos de 150 palabras',
  ejemplo: 'Ej.: Causa: desigualdad en la tenencia de la tierra…',
  tecnicas: 'Ej.: No inventes datos. Antes de responder, hazme 3 preguntas.',
};

/**
 * Evaluador de IA con constructor guiado: cada ingrediente del prompt se escribe en
 * su propio campo y el servidor lo califica por separado (calidad, estructura y
 * requisitos de la misión). Sin costo: no usa ninguna IA externa.
 */
@Component({
  imports: [FormsModule, RouterLink],
  templateUrl: './prompt-evaluator.page.html',
})
export class PromptEvaluatorPage {
  private readonly content = inject(ContentService);
  private readonly route = inject(ActivatedRoute);

  protected readonly isStaff = inject(AuthService).isStaff;
  protected readonly placeholders = PLACEHOLDERS;

  protected readonly missions = signal<Mission[]>([]);
  private readonly fieldsByRubric = signal<Record<PromptRubric, PromptField[]>>({
    basica: [],
    avanzada: [],
  });
  private readonly myRubric = signal<PromptRubric>('basica');

  /** null = modo libre. */
  protected readonly selectedId = signal<string | null>(null);
  protected readonly values = signal<PromptFields>({});
  protected readonly evaluation = signal<PromptEvaluation | null>(null);
  protected readonly lastAttempt = signal<PromptEvaluation | null>(null);
  protected readonly evaluating = signal(false);
  protected readonly sending = signal(false);
  protected readonly loading = signal(true);
  protected readonly error = signal('');
  protected readonly copied = signal(false);

  protected readonly mission = computed(
    () => this.missions().find((m) => m.id === this.selectedId()) ?? null,
  );
  protected readonly rubric = computed(() => this.mission()?.rubric ?? this.myRubric());
  protected readonly fields = computed(() => this.fieldsByRubric()[this.rubric()]);
  protected readonly hasText = computed(() =>
    Object.values(this.values()).some((v) => v.trim().length > 0),
  );

  /** Eficiencia (solo rúbrica avanzada) no es un campo: se muestra en el resumen. */
  protected readonly extraCriteria = computed(
    () => this.evaluation()?.criteria.filter((c) => !c.guided) ?? [],
  );

  /** Mejora del primer intento al mejor. */
  protected readonly improvement = computed(() => {
    const attempts = this.mission()?.attempts ?? [];
    if (attempts.length < 2) return null;
    const scores = attempts.map((a) => a.reviewedScore ?? a.score);
    const best = Math.max(...scores);
    return { first: scores[0], best, diff: best - scores[0] };
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

  protected setValue(key: string, value: string): void {
    this.values.update((all) => ({ ...all, [key]: value }));
    this.lastAttempt.set(null);
    this.schedulePreview();
  }

  /** Resultado de un campo en la última evaluación. */
  protected result(key: string) {
    return this.evaluation()?.criteria.find((c) => c.key === key) ?? null;
  }

  /** Lo que pide la misión en un campo (antes de evaluar). */
  protected missionRequirements(key: string): string[] {
    return (this.mission()?.requirements ?? []).filter((r) => r.field === key).map((r) => r.label);
  }

  protected levelIcon(level: string): string {
    return level === 'strong' ? '✓' : level === 'partial' ? '◐' : '✗';
  }

  protected clear(): void {
    this.values.set({});
    this.evaluation.set(null);
    this.lastAttempt.set(null);
  }

  protected async copyPrompt(): Promise<void> {
    const text = this.evaluation()?.composed;
    if (!text) return;
    try {
      await navigator.clipboard.writeText(text);
      this.copied.set(true);
      setTimeout(() => this.copied.set(false), 2000);
    } catch {
      // Sin permiso para el portapapeles: no pasa nada, el texto está a la vista.
    }
  }

  protected async submit(): Promise<void> {
    const mission = this.mission();
    if (!mission) return;

    this.sending.set(true);
    this.error.set('');
    try {
      const result = await this.content.submitPromptAttempt(mission.id, this.currentFields());
      this.evaluation.set(result);
      this.lastAttempt.set(result);
      this.missions.set(await this.content.getMissions());
    } catch (e) {
      this.error.set(e instanceof ContentError ? e.message : 'No pudimos enviar tu intento.');
    } finally {
      this.sending.set(false);
    }
  }

  /** Solo los campos de la rúbrica actual. */
  private currentFields(): PromptFields {
    const values = this.values();
    return Object.fromEntries(this.fields().map((f) => [f.key, values[f.key] ?? '']));
  }

  /** Vista previa: se pide al servidor un momento después de dejar de escribir. */
  private schedulePreview(): void {
    clearTimeout(this.previewTimer);
    if (!this.hasText()) {
      this.evaluation.set(null);
      return;
    }
    this.previewTimer = setTimeout(() => void this.preview(), PREVIEW_DELAY_MS);
  }

  private async preview(): Promise<void> {
    const id = ++this.previewId;
    this.evaluating.set(true);
    this.error.set('');
    try {
      const result = await this.content.evaluatePrompt(this.currentFields(), this.selectedId());
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
      const [missions, fields, rubric] = await Promise.all([
        this.content.getMissions(),
        this.content.getPromptFields(),
        this.content.getMyRubric(),
      ]);
      this.missions.set(missions);
      this.fieldsByRubric.set(fields);
      this.myRubric.set(rubric);

      // /evaluador?mision=<id> abre directamente esa misión (desde las lecciones).
      const requested = this.route.snapshot.queryParamMap.get('mision');
      const first = missions.find((m) => m.id === requested) ?? missions.find((m) => !m.passed);
      this.selectedId.set(first?.id ?? null);
    } catch {
      this.error.set('No pudimos cargar el evaluador.');
    } finally {
      this.loading.set(false);
    }
  }
}
