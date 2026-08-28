export interface JwtResponse {
  token: string;
  type?: string;
  username?: string;
  role?: string;
}

export type TaskStatus = "PENDING" | "IN_PROGRESS" | "COMPLETED" | "CANCELLED";

export interface Task {
  id: number;
  title: string;
  description: string | null;
  status: TaskStatus;
  userId: number;
  createdAt: string;
  updatedAt: string;
}
