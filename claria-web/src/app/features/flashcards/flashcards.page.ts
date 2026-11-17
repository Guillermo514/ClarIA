import { Component, computed, inject, signal } from '@angular/core';
import { ActivatedRoute } from '@angular/router';

import { ContentService } from '../../core/content/content.service';
import { Flashcard, LevelSummary } from '../../core/models/domain.models';

/** Distancia horizontal mínima (px) para que un deslizamiento cambie de tarjeta. */
const SWIPE_THRESHOLD = 50;

/** Sentido del último cambio de tarjeta; define desde qué lado entra la nueva. */
type CardDirection = 'next' | 'prev' | null;

/**
 * Repaso de las flashcards predeterminadas de cada nivel, con volteo y marcado
 * de tarjetas dominadas (se guarda en la base de datos).
 */
@Component({
  templateUrl: './flashcards.page.html',
  host: { '(document:keydown)': 'onKeydown($event)' },
})
export class FlashcardsPage {
  private readonly content = inject(ContentService);
  private readonly route = inject(ActivatedRoute);

  protected readonly unlockedLevels = computed(() =>
    this.content.levels().filter((level) => level.unlocked),
  );
  protected readonly selectedLevel = signal<LevelSummary | null>(null);

  protected readonly cards = signal<Flashcard[]>([]);
  protected readonly index = signal(0);
  protected readonly flipped = signal(false);
  protected readonly direction = signal<CardDirection>(null);
  protected readonly masteredIds = signal<string[]>([]);
  /** Tarjetas cuya respuesta ya vio: cuentan para poder presentar la evaluación. */
  protected readonly seenIds = signal<string[]>([]);
  protected readonly loading = signal(true);
  protected readonly saving = signal(false);
  protected readonly error = signal('');

  protected readonly card = computed(() => this.cards()[this.index()] ?? null);
  protected readonly seenPercent = computed(() =>
    this.cards().length ? (this.seenIds().length / this.cards().length) * 100 : 0,
  );

  /** Punto donde empezó el toque, para detectar el deslizamiento. */
  private touchStart: { x: number; y: number } | null = null;
  /** Evita que el clic que sigue a un deslizamiento voltee la tarjeta nueva. */
  private ignoreNextClick = false;

  constructor() {
    void this.init();
  }

  protected isMastered(): boolean {
    const card = this.card();
    return card ? this.masteredIds().includes(card.id) : false;
  }

  /** Texto inferior de cada cara; cada una conserva el suyo mientras la tarjeta gira. */
  protected statusLabel(face: 'front' | 'back'): string {
    if (this.isMastered()) return '✓ Tarjeta dominada';
    return face === 'back' ? 'Respuesta' : 'En proceso de aprendizaje';
  }

  protected async selectLevel(level: LevelSummary): Promise<void> {
    this.selectedLevel.set(level);
    this.loading.set(true);
    this.error.set('');
    this.cards.set([]);
    try {
      const cards = await this.content.getFlashcards(level.id);
      const states = await this.content.getCardStates(cards.map((c) => c.id));
      this.masteredIds.set(states.masteredIds);
      this.seenIds.set(states.seenIds);
      this.cards.set(cards);
      this.index.set(0);
      this.flipped.set(false);
      this.direction.set(null);
    } catch {
      this.error.set('No pudimos cargar las tarjetas.');
    } finally {
      this.loading.set(false);
    }
  }

  protected flip(): void {
    if (this.ignoreNextClick) {
      this.ignoreNextClick = false;
      return;
    }
    this.flipped.update((value) => !value);
    if (this.flipped()) void this.markSeen();
  }

  /** La primera vez que ve la respuesta se guarda en la cuenta. */
  private async markSeen(): Promise<void> {
    const card = this.card();
    if (!card || this.seenIds().includes(card.id)) return;
    this.seenIds.update((ids) => [...ids, card.id]);
    try {
      await this.content.markCardSeen(card.id);
      void this.content.refreshLevels();
    } catch {
      this.seenIds.update((ids) => ids.filter((id) => id !== card.id));
    }
  }

  /** Flechas ← → del teclado para cambiar de tarjeta (no mientras se escribe). */
  protected onKeydown(event: KeyboardEvent): void {
    if (isTypingTarget(event.target)) return;

    if (event.key === 'ArrowRight') this.move(1);
    else if (event.key === 'ArrowLeft') this.move(-1);
  }

  protected onTouchStart(event: TouchEvent): void {
    const touch = event.changedTouches[0];
    this.touchStart = { x: touch.clientX, y: touch.clientY };
  }

  /** Deslizar a la izquierda avanza; a la derecha regresa. */
  protected onTouchEnd(event: TouchEvent): void {
    if (!this.touchStart) return;

    const touch = event.changedTouches[0];
    const dx = touch.clientX - this.touchStart.x;
    const dy = touch.clientY - this.touchStart.y;
    this.touchStart = null;

    if (Math.abs(dx) < SWIPE_THRESHOLD || Math.abs(dx) < Math.abs(dy)) return;

    this.ignoreNextClick = true;
    setTimeout(() => (this.ignoreNextClick = false), 400);
    this.move(dx < 0 ? 1 : -1);
  }

  protected async markMastered(): Promise<void> {
    const card = this.card();
    if (!card || this.isMastered()) return;

    this.saving.set(true);
    try {
      await this.content.setCardMastered(card.id);
      this.masteredIds.update((ids) => [...ids, card.id]);
    } catch {
      this.error.set('No pudimos guardar la tarjeta. Inténtalo de nuevo.');
    } finally {
      this.saving.set(false);
    }
  }

  protected move(step: number): void {
    const total = this.cards().length;
    if (!total) return;
    this.direction.set(step > 0 ? 'next' : 'prev');
    this.index.update((i) => (i + step + total) % total);
    this.flipped.set(false);
  }

  private async init(): Promise<void> {
    try {
      await this.content.ensureLevels();
      // /flashcards?nivel=3 abre directamente las tarjetas de ese nivel.
      const requested = Number(this.route.snapshot.queryParamMap.get('nivel'));
      const first =
        this.unlockedLevels().find((l) => l.levelNumber === requested) ??
        this.content.currentLevel() ??
        this.unlockedLevels()[0];
      if (first) {
        await this.selectLevel(first);
        // …y &leccion=1.2 empieza en las tarjetas de esa lección.
        const lesson = this.route.snapshot.queryParamMap.get('leccion');
        const index = this.cards().findIndex((c) => c.lessonCode === lesson);
        if (index > 0) this.index.set(index);
      } else this.loading.set(false);
    } catch {
      this.error.set('No pudimos cargar tus niveles.');
      this.loading.set(false);
    }
  }
}

/** Indica si el evento viene de un campo donde el usuario está escribiendo. */
function isTypingTarget(target: EventTarget | null): boolean {
  return (
    target instanceof HTMLElement &&
    (target.isContentEditable || ['INPUT', 'TEXTAREA', 'SELECT'].includes(target.tagName))
  );
}
