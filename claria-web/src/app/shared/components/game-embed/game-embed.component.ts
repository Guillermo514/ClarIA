import { Component, computed, inject, input, model, signal } from '@angular/core';
import { DomSanitizer, SafeResourceUrl } from '@angular/platform-browser';

import { ContentError, ContentService } from '../../../core/content/content.service';
import { createCountdown } from '../../../core/content/countdown';

/** Mismo formato que valida la base de datos (lesson_activities.embed_url). */
const ALLOWED_GAME_URL = /^https:\/\/es\.educaplay\.com\/juego\/\d+-[\w-]+\.html$/;

/**
 * Juego de Educaplay embebido.
 * - No carga nada hasta que el estudiante pulsa «Jugar»: la lección abre rápido.
 * - Educaplay no avisa cuando el juego termina, así que tras 30 s de juego (medidos
 *   por el servidor) se habilita «Terminé el juego».
 * - Solo acepta URLs de Educaplay.
 */
@Component({
  selector: 'app-game-embed',
  templateUrl: './game-embed.component.html',
})
export class GameEmbedComponent {
  private readonly sanitizer = inject(DomSanitizer);
  private readonly content = inject(ContentService);

  readonly activityId = input.required<string>();
  readonly url = input.required<string>();
  readonly title = input('Dinámica interactiva');
  /** Se sincroniza con la lección para saber si ya puede completarla. */
  readonly completed = model(false);

  protected readonly playing = signal(false);
  protected readonly busy = signal(false);
  protected readonly error = signal('');
  protected readonly countdown = createCountdown();

  protected readonly safeUrl = computed<SafeResourceUrl | null>(() =>
    ALLOWED_GAME_URL.test(this.url())
      ? this.sanitizer.bypassSecurityTrustResourceUrl(this.url())
      : null,
  );

  protected async play(): Promise<void> {
    this.playing.set(true);
    this.error.set('');
    if (this.completed()) return;
    try {
      const start = await this.content.startActivity(this.activityId());
      this.countdown.start(start.secondsRemaining);
    } catch (e) {
      this.error.set(e instanceof ContentError ? e.message : 'No pudimos iniciar el juego.');
    }
  }

  protected async finish(): Promise<void> {
    this.busy.set(true);
    this.error.set('');
    try {
      await this.content.completeActivity(this.activityId());
      this.completed.set(true);
    } catch (e) {
      this.error.set(e instanceof ContentError ? e.message : 'No pudimos guardar tu avance.');
    } finally {
      this.busy.set(false);
    }
  }
}
