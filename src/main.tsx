import React from 'react';
import ReactDOM from 'react-dom/client';
import App from './App';
import DeclarationPage from './declaration/DeclarationPage';
import ExtraWorkPage from './extrawork/ExtraWorkPage';
import BenuCourierPage from './benu/BenuCourierPage';
import BenuPharmacyPage from './benu/BenuPharmacyPage';
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

// Vier ingangen in één bundel. /declaratie is voor de koerier, /meerwerk voor de
// apotheek, /benu de BENU-tijdinvoer van de koerier en /benu-ph de reactie van
// de apotheek daarop; alle vier zonder inlog, dus alle vier vóór App met zijn
// sessiecontrole.
function Root() {
  if (path === '/declaratie') return <DeclarationPage token={token} />;
  if (path === '/meerwerk') return <ExtraWorkPage token={token} />;
  if (path === '/benu') return <BenuCourierPage token={token} />;
  if (path === '/benu-ph') return <BenuPharmacyPage token={token} />;
  return <App />;
}

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <Root />
  </React.StrictMode>,
);
