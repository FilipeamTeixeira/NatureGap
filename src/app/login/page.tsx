import Navbar from '@/components/layout/Navbar';
import LoginForm from '@/components/auth/LoginForm';

export default function LoginPage() {
  return (
    <div className="h-full flex flex-col">
      <Navbar activePath="/login" />

      <main className="flex-1 bg-[#F7F8F5] flex items-center justify-center px-6 py-12">
        <LoginForm />
      </main>
    </div>
  );
}
