import { Component, computed, inject, signal } from '@angular/core';
import { ActivatedRoute } from '@angular/router';

import { ContentService } from '../../core/content/content.service';
import { Article } from '../../core/models/domain.models';
import { TextBlocksComponent } from '../../shared/components/text-blocks/text-blocks.component';

/** Artículos de las lecciones de los niveles desbloqueados, con lectura en modal. */
@Component({
  imports: [TextBlocksComponent],
  templateUrl: './articles.page.html',
})
export class ArticlesPage {
  private readonly content = inject(ContentService);
  private readonly route = inject(ActivatedRoute);

  protected readonly articles = signal<Article[]>([]);
  protected readonly levelFilter = signal<number | null>(null);
  protected readonly opened = signal<Article | null>(null);
  protected readonly loading = signal(true);
  protected readonly error = signal('');

  protected readonly levelNumbers = computed(() => [
    ...new Set(this.articles().map((a) => a.levelNumber)),
  ]);
  protected readonly filtered = computed(() => {
    const level = this.levelFilter();
    return level === null
      ? this.articles()
      : this.articles().filter((a) => a.levelNumber === level);
  });

  constructor() {
    void this.load();
  }

  protected open(article: Article): void {
    this.opened.set(article);
  }

  protected close(): void {
    this.opened.set(null);
  }

  private async load(): Promise<void> {
    try {
      const levels = await this.content.ensureLevels();
      const unlocked = levels.filter((l) => l.unlocked).map((l) => l.id);
      this.articles.set(await this.content.getArticles(unlocked));

      // /articulos?leccion=1.2 abre directamente el artículo de esa lección.
      const lesson = this.route.snapshot.queryParamMap.get('leccion');
      const match = this.articles().find((a) => a.lessonCode === lesson);
      if (match) {
        this.levelFilter.set(match.levelNumber);
        this.open(match);
      }
    } catch {
      this.error.set('No pudimos cargar los artículos.');
    } finally {
      this.loading.set(false);
    }
  }
}
