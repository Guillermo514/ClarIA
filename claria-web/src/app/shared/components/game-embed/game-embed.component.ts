import { Component, computed, inject, input, signal } from '@angular/core';
import { DomSanitizer, SafeResourceUrl } from '@angular/platform-browser';

/** Mismo formato que valida la base de datos (lesson_activities.embed_url). */
const ALLOWED_GAME_URL = /^https:\/\/es\.educaplay\.com\/juego\/\d+-[\w-]+\.html$/;

/**
 * Juego de Educaplay embebido.
 * No carga nada hasta que el estudiante pulsa "Jugar": así la lección abre rápido
 * aunque el juego pese varios MB. Solo acepta URLs de Educaplay.
 */
@Component({
  selector: 'app-game-embed',
  templateUrl: './game-embed.component.html',
})
export class GameEmbedComponent {
  private readonly sanitizer = inject(DomSanitizer);

  readonly url = input.required<string>();
  readonly title = input('Dinámica interactiva');

  protected readonly playing = signal(false);

  protected readonly safeUrl = computed<SafeResourceUrl | null>(() =>
    ALLOWED_GAME_URL.test(this.url())
      ? this.sanitizer.bypassSecurityTrustResourceUrl(this.url())
      : null,
  );
}
