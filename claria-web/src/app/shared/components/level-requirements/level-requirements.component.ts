import { Component, input } from '@angular/core';
import { RouterLink } from '@angular/router';

import { LevelSummary } from '../../../core/models/domain.models';

/** Lo que falta en un nivel para poder presentar su evaluación final. */
@Component({
  selector: 'app-level-requirements',
  imports: [RouterLink],
  template: `
    @let lv = level();
    <section class="panel requirements">
      <div class="eyebrow">ANTES DE LA EVALUACIÓN</div>
      <b>
        {{
          lv.quizReady
            ? '¡Listo! Ya puedes presentar la evaluación.'
            : 'Completa todo el nivel para desbloquear la evaluación:'
        }}
      </b>
      <ul>
        <li [class.done]="lv.lessonsCompleted >= lv.lessonsTotal">
          <a [routerLink]="['/cursos', lv.levelNumber]">📘 Lecciones leídas</a>
          <span>{{ lv.lessonsCompleted }} / {{ lv.lessonsTotal }}</span>
        </li>
        @if (lv.gamesTotal > 0) {
          <li [class.done]="lv.gamesCompleted >= lv.gamesTotal">
            <a [routerLink]="['/cursos', lv.levelNumber]">🎮 Juegos terminados</a>
            <span>{{ lv.gamesCompleted }} / {{ lv.gamesTotal }}</span>
          </li>
        }
        <li [class.done]="lv.flashcardsSeen >= lv.flashcardsTotal">
          <a routerLink="/flashcards" [queryParams]="{ nivel: lv.levelNumber }"
            >▱ Flashcards volteadas</a
          >
          <span>{{ lv.flashcardsSeen }} / {{ lv.flashcardsTotal }}</span>
        </li>
      </ul>
    </section>
  `,
})
export class LevelRequirementsComponent {
  readonly level = input.required<LevelSummary>();
}
