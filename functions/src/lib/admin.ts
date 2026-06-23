import { initializeApp, getApps } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';
import { getStorage } from 'firebase-admin/storage';

// Single Admin SDK init shared across all functions. The Admin SDK bypasses
// Security Rules, so server code is the only writer of catalog + targets data.
if (getApps().length === 0) {
  initializeApp();
}

export const db = getFirestore();
export const storage = getStorage();
