import React from 'react';
import ReactDOM from 'react-dom/client';
import App from './App';
import DeclarationPage from './declaration/DeclarationPage';
import ExtraWorkPage from './extrawork/ExtraWorkPage';
import './index.css';

// Twee ingangen in één bundel. /declaratie?t=<token> is de pagina uit de
// nabericht-mail: die moet zónder inlog werken, dus hij wordt hier gekozen vóór
// App met zijn sessiecontrole in beeld komt.
//
// Er is bewust geen router-bibliotheek: er zijn twee paden, en een vergelijking
// op pathname is minder om te onderhouden dan een afhankelijkheid.
// Netlify heeft public/_redirects nodig om /declaratie naar index.html te sturen.
const path = window.location.pathname.replace(/\/+$/, '');
const token = new URLSearchParams(window.location.search).get('t') ?? '';

// Drie ingangen in één bundel. /declaratie is voor de koerier, /meerwerk voor de
// apotheek; allebei zonder inlog, dus allebei vóór App met zijn sessiecontrole.
function Root() {
  if (path === '/declaratie') return <DeclarationPage token={token} />;
  if (path === '/meerwerk') return <ExtraWorkPage token={token} />;
  return <App />;
}

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <Root />
  </React.StrictMode>,
);
