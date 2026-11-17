import { Component, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Router, RouterLink } from '@angular/router';

import { AuthService } from '../../core/auth/auth.service';
import { AcademicLevel, SignUpData } from '../../core/models/domain.models';

/** Edad mínima para usar ClarIA (la base de datos también la valida). */
const MIN_AGE = 8;
const MIN_PASSWORD = 8;

function ageFrom(birthDate: string): number {
  const birth = new Date(`${birthDate}T00:00:00`);
  const today = new Date();
  let age = today.getFullYear() - birth.getFullYear();
  const beforeBirthday =
    today.getMonth() < birth.getMonth() ||
    (today.getMonth() === birth.getMonth() && today.getDate() < birth.getDate());
  if (beforeBirthday) age--;
  return age;
}

/** Registro de estudiantes. El grupo de edad se calcula con la fecha de nacimiento. */
@Component({
  imports: [FormsModule, RouterLink],
  templateUrl: './register.page.html',
})
export class RegisterPage {
  private readonly auth = inject(AuthService);
  private readonly router = inject(Router);

  protected readonly academicLevels: { value: AcademicLevel; label: string }[] = [
    { value: 'primaria', label: 'Primaria' },
    { value: 'secundaria', label: 'Secundaria' },
    { value: 'preparatoria', label: 'Preparatoria' },
    { value: 'universidad', label: 'Universidad' },
    { value: 'otro', label: 'Otro' },
  ];

  /** Fecha máxima del calendario: hoy. */
  protected readonly today = new Date().toISOString().slice(0, 10);

  protected form: SignUpData = {
    fullName: '',
    birthDate: '',
    institution: '',
    academicLevel: '',
    email: '',
    password: '',
  };
  protected confirmPassword = '';
  protected acceptedPrivacy = false;

  protected readonly error = signal('');
  protected readonly loading = signal(false);
  protected readonly checkEmail = signal(false);

  protected async submit(): Promise<void> {
    const problem = this.validate();
    if (problem) {
      this.error.set(problem);
      return;
    }

    this.loading.set(true);
    this.error.set('');
    const { error, needsConfirmation } = await this.auth.signUp(this.form);
    this.loading.set(false);

    if (error) this.error.set(error);
    else if (needsConfirmation) this.checkEmail.set(true);
    else await this.router.navigateByUrl('/inicio');
  }

  private validate(): string | null {
    const { fullName, birthDate, institution, email, password } = this.form;
    if (fullName.trim().length < 2) return 'Escribe tu nombre (al menos 2 letras).';
    if (fullName.trim().length > 100) return 'El nombre es demasiado largo.';
    if (!birthDate) return 'Indica tu fecha de nacimiento.';
    const age = ageFrom(birthDate);
    if (Number.isNaN(age) || age > 120) return 'La fecha de nacimiento no es válida.';
    if (age < MIN_AGE) return `ClarIA está dirigida a personas de ${MIN_AGE} años en adelante.`;
    if (institution.trim() && institution.trim().length < 2)
      return 'El nombre de la escuela es muy corto.';
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email.trim())) return 'Escribe un correo válido.';
    if (password.length < MIN_PASSWORD)
      return `La contraseña debe tener al menos ${MIN_PASSWORD} caracteres.`;
    if (password !== this.confirmPassword) return 'Las contraseñas no coinciden.';
    if (!this.acceptedPrivacy) return 'Debes aceptar el aviso de privacidad para continuar.';
    return null;
  }
}
