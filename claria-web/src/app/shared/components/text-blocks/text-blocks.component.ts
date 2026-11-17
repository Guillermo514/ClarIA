import { Component, computed, input } from '@angular/core';

import { toTextBlocks } from '../../../core/content/text-blocks';

/** Muestra un texto de la base de datos como párrafos y listas. */
@Component({
  selector: 'app-text-blocks',
  template: `
    @for (block of blocks(); track $index) {
      @if (block.kind === 'paragraph') {
        <p>{{ block.text }}</p>
      } @else {
        <ul>
          @for (item of block.items; track $index) {
            <li>
              @if (item.label) {
                <b>{{ item.label }}:</b>
              }
              {{ item.text }}
            </li>
          }
        </ul>
      }
    }
  `,
  host: { class: 'text-blocks' },
})
export class TextBlocksComponent {
  readonly text = input.required<string>();
  protected readonly blocks = computed(() => toTextBlocks(this.text()));
}
