import type { ReactNode } from "react";
import { Navigate, useLocation } from "react-router";
import { getToken } from "../api";

interface ProtectedRouteProps {
  children: ReactNode;
}

export default function ProtectedRoute({ children }: ProtectedRouteProps) {
  const location = useLocation();

  if (!getToken()) {
    return (
      <Navigate
        to="/login"
        replace
        state={{
          from: `${location.pathname}${location.search}${location.hash}`,
        }}
      />
    );
  }

  return <>{children}</>;
}
