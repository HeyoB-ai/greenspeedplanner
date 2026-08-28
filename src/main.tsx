import React from 'react';
import ReactDOM from 'react-dom/client';
import App from './App';
import DeclarationPage from './declaration/DeclarationPage';
import './index.css';

// Twee ingangen in één bundel. /declaratie?t=<token> is de pagina uit de
// nabericht-mail: die moet zónder inlog werken, dus hij wordt hier gekozen vóór
// App met zijn sessiecontrole in beeld komt.
//
// Er is bewust geen router-bibliotheek: er zijn twee paden, en een vergelijking
// op pathname is minder om te onderhouden dan een afhankelijkheid.
// Netlify heeft public/_redirects nodig om /declaratie naar index.html te sturen.
const path = window.location.pathname.replace(/\/+$/, '');
const isDeclaration = path === '/declaratie';
const token = new URLSearchParams(window.location.search).get('t') ?? '';

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    {isDeclaration ? <DeclarationPage token={token} /> : <App />}
  </React.StrictMode>,
);
