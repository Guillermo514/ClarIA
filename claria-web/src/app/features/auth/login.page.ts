import { Component, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Router, RouterLink } from '@angular/router';

import { AuthService } from '../../core/auth/auth.service';

/** Inicio de sesión con correo y contraseña. */
@Component({
  imports: [FormsModule, RouterLink],
  templateUrl: './login.page.html',
})
export class LoginPage {
  private readonly auth = inject(AuthService);
  private readonly router = inject(Router);

  protected email = '';
  protected password = '';
  protected readonly error = signal('');
  protected readonly loading = signal(false);

  protected async submit(): Promise<void> {
    if (!this.email.trim() || !this.password) {
      this.error.set('Escribe tu correo y tu contraseña.');
      return;
    }

    this.loading.set(true);
    this.error.set('');
    const error = await this.auth.signIn(this.email.trim(), this.password);
    this.loading.set(false);

    if (error) this.error.set(error);
    else await this.router.navigateByUrl('/inicio');
  }
}
