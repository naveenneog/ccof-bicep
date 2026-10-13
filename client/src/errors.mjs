export class ClientError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'ClientError';
    this.code = code;
  }
}

export function signInRequired() {
  return new ClientError('sign_in_required',
    'Sign-in is required. Run ccof-token login, then retry. Token acquisition is silent only.');
}

export async function bounded(operation, seconds) {
  let timer;
  try {
    return await Promise.race([
      operation(),
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new ClientError('authentication_timeout',
          'Authentication timed out. Run ccof-token login and retry.')), seconds * 1000);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}
