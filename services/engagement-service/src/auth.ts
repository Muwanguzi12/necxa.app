import { Request, Response, NextFunction } from 'express';
import jwt from 'jsonwebtoken';

export interface AuthRequest extends Request {
  user?: any;
}

export function authMiddleware(req: AuthRequest, res: Response, next: NextFunction) {
  const header = req.headers.authorization;
  const secret = process.env.JWT_SECRET;
  if (!header) {
    return res.status(401).json({ message: 'missing Authorization header' });
  }
  const parts = header.split(' ');
  if (parts.length !== 2 || parts[0] !== 'Bearer') {
    return res.status(401).json({ message: 'malformed Authorization header' });
  }
  const token = parts[1];
  if (!secret) {
    // In local/dev, if no secret provided, accept token as a simple "sub:..." format for convenience.
    try {
      req.user = { sub: token };
      return next();
    } catch (err) {
      return res.status(401).json({ message: 'unauthorized' });
    }
  }

  try {
    const payload = jwt.verify(token, secret);
    req.user = payload;
    next();
  } catch (err) {
    return res.status(401).json({ message: 'invalid token' });
  }
}
